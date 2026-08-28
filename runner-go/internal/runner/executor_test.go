package runner

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/robine-ci/robine-runner/internal/config"
)

type recordedRequest struct {
	event   string
	payload map[string]any
}

type fakeRequester struct {
	mu       sync.Mutex
	requests []recordedRequest
	notify   chan recordedRequest
}

func (f *fakeRequester) Request(_ context.Context, event string, payload any) (map[string]any, error) {
	encoded, _ := json.Marshal(payload)
	var normalized map[string]any
	_ = json.Unmarshal(encoded, &normalized)
	request := recordedRequest{event: event, payload: normalized}
	f.mu.Lock()
	f.requests = append(f.requests, request)
	f.mu.Unlock()
	if f.notify != nil {
		select {
		case f.notify <- request:
		default:
		}
	}
	return map[string]any{"acknowledged": true}, nil
}

func (f *fakeRequester) snapshot() []recordedRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]recordedRequest(nil), f.requests...)
}

func TestExecutorBuildsMacAppAndUploadsArtifact(t *testing.T) {
	var uploaded []byte
	var uploadedQuery url.Values
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Header.Get("Authorization") != "Bearer runner-secret" || request.Header.Get("X-Robine-Runner-Id") != "runner-1" {
			http.Error(response, "unauthorized", http.StatusUnauthorized)
			return
		}
		switch {
		case request.Method == http.MethodGet && request.URL.Path == "/secrets":
			response.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(response, `{"secrets":{"TOKEN":"super-secret"}}`)
		case request.Method == http.MethodPut && request.URL.Path == "/attempt/artifacts":
			uploadedQuery = request.URL.Query()
			uploaded, _ = io.ReadAll(request.Body)
			response.WriteHeader(http.StatusCreated)
			_, _ = io.WriteString(response, `{}`)
		default:
			http.NotFound(response, request)
		}
	}))
	defer server.Close()

	channel := &fakeRequester{}
	executor := newExecutor(channel, newTransferClient(config.Config{RunnerID: "runner-1", Credential: "runner-secret"}))
	offer := testOffer(server.URL, []Step{
		{Name: "Build app", Kind: "run", Value: "mkdir -p Demo.app/Contents/MacOS; printf executable > Demo.app/Contents/MacOS/Demo; chmod +x Demo.app/Contents/MacOS/Demo; printf '%s' \"$TOKEN\"", Condition: "success", With: map[string]any{}},
		{Name: "Upload app", Kind: "builtin", Value: "artifacts/upload", Condition: "success", With: map[string]any{"name": "Demo-${{ runner.os }}-${{ runner.arch }}", "paths": []any{"Demo.app"}, "retention-days": float64(14)}},
	})
	if err := executor.Run(context.Background(), offer); err != nil {
		t.Fatal(err)
	}
	if len(uploaded) == 0 {
		t.Fatal("artifact was not uploaded")
	}
	if uploadedQuery.Get("retention_days") != "14" || !strings.HasPrefix(uploadedQuery.Get("name"), "Demo-") {
		t.Fatalf("unexpected artifact query: %v", uploadedQuery)
	}
	if !archiveContains(t, uploaded, "Demo.app/Contents/MacOS/Demo", "executable") {
		t.Fatal("uploaded archive does not contain the built app")
	}

	requests := channel.snapshot()
	if !hasAttemptStatus(requests, "running") || !hasAttemptStatus(requests, "succeeded") {
		t.Fatalf("missing lifecycle events: %#v", requests)
	}
	for _, request := range requests {
		if request.event == "log_event" && strings.Contains(request.payload["content"].(string), "super-secret") {
			t.Fatal("secret leaked into logs")
		}
	}
	if !hasLogContent(requests, "[REDACTED]") {
		t.Fatal("redacted command output was not delivered")
	}
}

func TestExecutorReportsFailureAndRunsFailureCondition(t *testing.T) {
	server := secretServer(t)
	defer server.Close()
	channel := &fakeRequester{}
	executor := newExecutor(channel, newTransferClient(config.Config{RunnerID: "runner-1", Credential: "runner-secret"}))
	offer := testOffer(server.URL, []Step{
		{Name: "Fail", Kind: "run", Value: "printf failed; exit 9", Condition: "success", With: map[string]any{}},
		{Name: "Skipped", Kind: "run", Value: "printf wrong", Condition: "success", With: map[string]any{}},
		{Name: "Diagnostic", Kind: "run", Value: "printf diagnostic", Condition: "failure", With: map[string]any{}},
	})
	if err := executor.Run(context.Background(), offer); err != nil {
		t.Fatal(err)
	}
	requests := channel.snapshot()
	if !hasAttemptReason(requests, "failed", "command_failed") || !hasStepStatus(requests, "Skipped", "skipped") || !hasLogContent(requests, "diagnostic") {
		t.Fatalf("unexpected failure lifecycle: %#v", requests)
	}
}

func TestExecutorCancelsProcessGroupAndCleansWorkspace(t *testing.T) {
	server := secretServer(t)
	defer server.Close()
	channel := &fakeRequester{notify: make(chan recordedRequest, 32)}
	executor := newExecutor(channel, newTransferClient(config.Config{RunnerID: "runner-1", Credential: "runner-secret"}))
	offer := testOffer(server.URL, []Step{{Name: "Wait", Kind: "run", Value: "sleep 30", Condition: "success", With: map[string]any{}}})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- executor.Run(ctx, offer) }()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case request := <-channel.notify:
			if request.event == "log_event" && request.payload["step_name"] == "Wait" && request.payload["status"] == "running" {
				cancel()
				goto cancelled
			}
		case <-deadline:
			t.Fatal("command did not start")
		}
	}

cancelled:
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cancelled command did not stop")
	}
	if !hasAttemptReason(channel.snapshot(), "cancelled", "cancelled") {
		t.Fatalf("missing cancelled terminal event: %#v", channel.snapshot())
	}
}

func TestBuiltinsSaveRestoreAndDownload(t *testing.T) {
	workspace := t.TempDir()
	if err := os.MkdirAll(filepath.Join(workspace, "cache"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace, "cache", "value"), []byte("cached"), 0o644); err != nil {
		t.Fatal(err)
	}
	artifactWorkspace := t.TempDir()
	if err := os.MkdirAll(filepath.Join(artifactWorkspace, "Downloaded.app"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(artifactWorkspace, "Downloaded.app", "value"), []byte("artifact"), 0o644); err != nil {
		t.Fatal(err)
	}
	artifactBody, err := createArchive(artifactWorkspace, []string{"Downloaded.app"})
	if err != nil {
		t.Fatal(err)
	}
	artifactDigest := sha256.Sum256(artifactBody)
	var cacheBody []byte
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		switch {
		case request.Method == http.MethodPut && request.URL.Path == "/attempt/cache":
			cacheBody, _ = io.ReadAll(request.Body)
			response.WriteHeader(http.StatusCreated)
		case request.Method == http.MethodGet && request.URL.Path == "/attempt/cache":
			if len(cacheBody) == 0 {
				response.WriteHeader(http.StatusNoContent)
			} else {
				_, _ = response.Write(cacheBody)
			}
		case request.Method == http.MethodGet && request.URL.Path == "/attempt/artifacts":
			response.Header().Set("X-Content-Sha256", hex.EncodeToString(artifactDigest[:]))
			_, _ = response.Write(artifactBody)
		default:
			http.NotFound(response, request)
		}
	}))
	defer server.Close()
	executor := newExecutor(&fakeRequester{}, newTransferClient(config.Config{RunnerID: "runner", Credential: "secret"}))
	offer := testOffer(server.URL, []Step{{Name: "unused", Kind: "run", Value: "true"}})

	if err := executor.executeBuiltin(context.Background(), offer, workspace, Step{Value: "cache/save", With: map[string]any{"key": "v1", "paths": []any{"cache"}}}); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(filepath.Join(workspace, "cache")); err != nil {
		t.Fatal(err)
	}
	if err := executor.executeBuiltin(context.Background(), offer, workspace, Step{Value: "cache/restore", With: map[string]any{"key": "v1"}}); err != nil {
		t.Fatal(err)
	}
	if value, err := os.ReadFile(filepath.Join(workspace, "cache", "value")); err != nil || string(value) != "cached" {
		t.Fatalf("cache was not restored: %q %v", value, err)
	}
	if err := executor.executeBuiltin(context.Background(), offer, workspace, Step{Value: "artifacts/download", With: map[string]any{"name": "app", "from": "build", "path": "downloads"}}); err != nil {
		t.Fatal(err)
	}
	if value, err := os.ReadFile(filepath.Join(workspace, "downloads", "Downloaded.app", "value")); err != nil || string(value) != "artifact" {
		t.Fatalf("artifact was not restored: %q %v", value, err)
	}

	invalid := []Step{
		{Value: "cache/save", With: map[string]any{"key": "v1", "paths": "bad"}},
		{Value: "cache/restore", With: map[string]any{}},
		{Value: "artifacts/download", With: map[string]any{"name": "missing-from"}},
		{Value: "unsupported", With: map[string]any{}},
	}
	for _, step := range invalid {
		if err := executor.executeBuiltin(context.Background(), offer, workspace, step); err == nil {
			t.Fatalf("invalid builtin accepted: %#v", step)
		}
	}
}

func TestExecutorPreparationFailureAndTimeout(t *testing.T) {
	server := secretServer(t)
	defer server.Close()
	channel := &fakeRequester{}
	executor := newExecutor(channel, newTransferClient(config.Config{RunnerID: "runner", Credential: "secret"}))
	offer := testOffer(server.URL, []Step{{Name: "Wait", Kind: "run", Value: "sleep 2", Condition: "success"}})
	offer.Execution.TimeoutMS = 30
	if err := executor.Run(context.Background(), offer); err != nil {
		t.Fatal(err)
	}
	if !hasAttemptReason(channel.snapshot(), "failed", "timeout") {
		t.Fatalf("timeout not reported: %#v", channel.snapshot())
	}

	channel = &fakeRequester{}
	executor = newExecutor(channel, newTransferClient(config.Config{RunnerID: "runner", Credential: "secret"}))
	offer = testOffer(server.URL, []Step{{Name: "Never", Kind: "run", Value: "true"}})
	offer.Execution.Services = map[string]json.RawMessage{"postgres": json.RawMessage(`{}`)}
	if err := executor.Run(context.Background(), offer); err == nil {
		t.Fatal("native services were accepted")
	}
	if !hasAttemptReason(channel.snapshot(), "failed", "system_failure") {
		t.Fatalf("preparation failure not reported: %#v", channel.snapshot())
	}
}

func testOffer(serverURL string, steps []Step) Offer {
	return Offer{
		AttemptID: "attempt-1", IdempotencyToken: "token-1", SecretsURL: serverURL + "/secrets", BuiltinsURL: serverURL + "/attempt",
		Execution: Execution{AttemptID: "attempt-1", IdempotencyToken: "token-1", Image: "native", Shell: "/bin/sh", TimeoutMS: 5000, Env: map[string]string{}, BuildEnv: map[string]string{"ROBINE_BUILD_COMMIT_SHA": "abc"}, SecretNames: []string{"TOKEN"}, Steps: steps},
	}
}

func secretServer(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/secrets" {
			http.NotFound(response, request)
			return
		}
		_, _ = io.WriteString(response, `{"secrets":{}}`)
	}))
}

func archiveContains(t *testing.T, body []byte, name, content string) bool {
	t.Helper()
	gz, err := gzip.NewReader(strings.NewReader(string(body)))
	if err != nil {
		t.Fatal(err)
	}
	defer gz.Close()
	reader := tar.NewReader(gz)
	for {
		header, err := reader.Next()
		if err == io.EOF {
			return false
		}
		if err != nil {
			t.Fatal(err)
		}
		if header.Name == name {
			value, _ := io.ReadAll(reader)
			return string(value) == content
		}
	}
}

func hasAttemptStatus(requests []recordedRequest, status string) bool {
	for _, request := range requests {
		if request.event == "attempt_event" && request.payload["status"] == status {
			return true
		}
	}
	return false
}

func hasAttemptReason(requests []recordedRequest, status, reason string) bool {
	for _, request := range requests {
		if request.event == "attempt_event" && request.payload["status"] == status && request.payload["reason"] == reason {
			return true
		}
	}
	return false
}

func hasStepStatus(requests []recordedRequest, name, status string) bool {
	for _, request := range requests {
		if request.event == "log_event" && request.payload["step_name"] == name && request.payload["status"] == status {
			return true
		}
	}
	return false
}

func hasLogContent(requests []recordedRequest, content string) bool {
	for _, request := range requests {
		if request.event == "log_event" && strings.Contains(request.payload["content"].(string), content) {
			return true
		}
	}
	return false
}
