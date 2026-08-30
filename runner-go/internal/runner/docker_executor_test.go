package runner

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/robine-ci/robine-runner/internal/config"
)

func TestDockerExecutorRunsServiceRedactsAndUploads(t *testing.T) {
	if err := dockerReady(context.Background()); err != nil {
		t.Skip("Docker Engine is unavailable")
	}
	namespace := "test-" + strings.ToLower(safeID(t.Name())) + "-" + strconvTimestamp()
	config := config.Config{
		Executor:          "docker",
		ResourceNamespace: namespace,
		CPUMillis:         1_000,
		MemoryBytes:       256 * 1024 * 1024,
		PIDsLimit:         128,
	}
	defer reconcileDocker(context.Background(), config, nil)

	seedRoot := t.TempDir()
	if err := os.MkdirAll(filepath.Join(seedRoot, "downloaded"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(seedRoot, "downloaded", "value"), []byte("downloaded"), 0o644); err != nil {
		t.Fatal(err)
	}
	seedArtifact, err := createArchive(seedRoot, []string{"downloaded"})
	if err != nil {
		t.Fatal(err)
	}
	seedDigest := sha256.Sum256(seedArtifact)
	sourceRoot := t.TempDir()
	if err := os.MkdirAll(filepath.Join(sourceRoot, "source"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sourceRoot, "source", "source-value"), []byte("checked-out"), 0o644); err != nil {
		t.Fatal(err)
	}
	sourceArchive, err := createArchive(sourceRoot, []string{"source"})
	if err != nil {
		t.Fatal(err)
	}
	var artifact, cache []byte
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		switch {
		case request.Method == http.MethodGet && request.URL.Path == "/secrets":
			_, _ = io.WriteString(response, `{"secrets":{"TOKEN":"docker-super-secret","DB_PASSWORD":"database-super-secret"}}`)
		case request.Method == http.MethodPut && request.URL.Path == "/attempt/artifacts":
			artifact, _ = io.ReadAll(request.Body)
			digest := sha256.Sum256(artifact)
			response.WriteHeader(http.StatusCreated)
			_, _ = io.WriteString(response, `{"digest":"`+hex.EncodeToString(digest[:])+`"}`)
		case request.Method == http.MethodGet && request.URL.Path == "/attempt/artifacts":
			response.Header().Set("X-Content-Sha256", hex.EncodeToString(seedDigest[:]))
			_, _ = response.Write(seedArtifact)
		case request.Method == http.MethodPut && request.URL.Path == "/attempt/cache":
			cache, _ = io.ReadAll(request.Body)
			digest := sha256.Sum256(cache)
			response.WriteHeader(http.StatusCreated)
			_, _ = io.WriteString(response, `{"digest":"`+hex.EncodeToString(digest[:])+`"}`)
		case request.Method == http.MethodGet && request.URL.Path == "/attempt/cache":
			digest := sha256.Sum256(cache)
			response.Header().Set("X-Content-Sha256", hex.EncodeToString(digest[:]))
			_, _ = response.Write(cache)
		case request.Method == http.MethodGet && request.URL.Path == "/source":
			digest := sha256.Sum256(sourceArchive)
			response.Header().Set("X-Content-Sha256", hex.EncodeToString(digest[:]))
			_, _ = response.Write(sourceArchive)
		default:
			http.NotFound(response, request)
		}
	}))
	defer server.Close()

	postgres, _ := json.Marshal(dockerService{
		ID: "postgres", Image: "postgres:18-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15",
		User:      "postgres",
		SecretEnv: map[string]string{"POSTGRES_PASSWORD": "DB_PASSWORD"},
		Readiness: &dockerReadiness{TCP: 5432, TimeoutMS: 30_000},
	})
	redis, _ := json.Marshal(dockerService{
		ID: "redis", Image: "redis@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241",
		Readiness: &dockerReadiness{TCP: 6379, TimeoutMS: 30_000},
	})
	offer := Offer{
		AttemptID:        "docker-attempt",
		IdempotencyToken: "docker-token",
		SecretsURL:       server.URL + "/secrets",
		BuiltinsURL:      server.URL + "/attempt",
		SourceURL:        stringPointer(server.URL + "/source"),
		Execution: Execution{
			AttemptID: "docker-attempt", IdempotencyToken: "docker-token",
			Image: dockerReadinessImage, Shell: "/bin/sh", TimeoutMS: 60_000,
			Env: map[string]string{}, BuildEnv: map[string]string{"ROBINE_BUILD_COMMIT_SHA": "abc"}, SecretNames: []string{"TOKEN", "DB_PASSWORD"},
			Services: map[string]json.RawMessage{"postgres": postgres, "redis": redis},
			Steps: []Step{
				{Name: "Build", Kind: "run", Condition: "success", Value: "nc -z postgres 5432; nc -z redis 6379; test \"$(cat source-value)\" = checked-out; printf '#!/bin/sh\\nexit 0\\n' >/tmp/generated-test; chmod +x /tmp/generated-test; /tmp/generated-test; mkdir -p output deps; printf artifact >output/value; printf cached >deps/value; printf '%s' \"$TOKEN\""},
				{Name: "Save cache", Kind: "builtin", Condition: "success", Value: "cache/save", With: map[string]any{"key": "docker-cache", "paths": []any{"deps"}}},
				{Name: "Clear cache", Kind: "run", Condition: "success", Value: "rm -rf deps"},
				{Name: "Restore cache", Kind: "builtin", Condition: "success", Value: "cache/restore", With: map[string]any{"key": "docker-cache", "paths": []any{"deps"}}},
				{Name: "Download artifact", Kind: "builtin", Condition: "success", Value: "artifacts/download", With: map[string]any{"name": "seed", "from": "seed-job", "path": "imports"}},
				{Name: "Verify transfers", Kind: "run", Condition: "success", Value: "test \"$(cat deps/value)\" = cached; test \"$(cat imports/downloaded/value)\" = downloaded"},
				{Name: "Upload", Kind: "builtin", Condition: "success", Value: "artifacts/upload", With: map[string]any{"name": "docker-output", "paths": []any{"output"}, "retention-days": float64(7)}},
			},
		},
	}
	channel := &fakeRequester{}
	executor := newConfiguredExecutor(config, channel, newTransferClient(configForTransfers(server.URL)))
	if err := executor.Run(context.Background(), offer); err != nil {
		t.Fatal(err)
	}
	if len(artifact) == 0 || !archiveContains(t, artifact, "output/value", "artifact") {
		t.Fatal("Docker artifact was not uploaded")
	}
	requests := channel.snapshot()
	if !hasAttemptStatus(requests, "succeeded") || !hasStepStatus(requests, "Service postgres", "succeeded") || !hasStepStatus(requests, "Service redis", "succeeded") {
		t.Fatalf("Docker lifecycle is incomplete: %#v", requests)
	}
	for _, request := range requests {
		if request.event == "log_event" {
			if content, _ := request.payload["content"].(string); strings.Contains(content, "docker-super-secret") {
				t.Fatal("secret leaked from Docker execution")
			}
		}
	}
	if !hasLogContent(requests, "[REDACTED]") {
		t.Fatal("Docker output was not redacted")
	}
	assertNoDockerResources(t, namespace)
}

func TestDockerExecutorRedactsFailedServiceDiagnostic(t *testing.T) {
	if err := dockerReady(context.Background()); err != nil {
		t.Skip("Docker Engine is unavailable")
	}
	namespace := "test-service-failure-" + strconvTimestamp()
	cfg := config.Config{Executor: "docker", ResourceNamespace: namespace, CPUMillis: 1_000, MemoryBytes: 128 * 1024 * 1024, PIDsLimit: 64}
	defer reconcileDocker(context.Background(), cfg, nil)
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/secrets" {
			_, _ = io.WriteString(response, `{"secrets":{"TOKEN":"service-super-secret"}}`)
			return
		}
		http.NotFound(response, request)
	}))
	defer server.Close()
	service, _ := json.Marshal(dockerService{
		ID: "broken", Image: dockerReadinessImage,
		Command:   []string{"sh", "-c", "printf '%s' \"$TOKEN\"; exit 9"},
		SecretEnv: map[string]string{"TOKEN": "TOKEN"},
		Readiness: &dockerReadiness{TCP: 9999, TimeoutMS: 1_000},
	})
	offer := testOffer(server.URL, []Step{{Name: "Never", Kind: "run", Value: "true", Condition: "success"}})
	offer.AttemptID, offer.IdempotencyToken = "service-failure", "service-token"
	offer.Execution.AttemptID, offer.Execution.IdempotencyToken = offer.AttemptID, offer.IdempotencyToken
	offer.Execution.Image = dockerReadinessImage
	offer.Execution.Services = map[string]json.RawMessage{"broken": service}
	channel := &fakeRequester{}
	executor := newConfiguredExecutor(cfg, channel, newTransferClient(configForTransfers(server.URL)))
	if err := executor.Run(context.Background(), offer); err == nil {
		t.Fatal("failed service was accepted")
	}
	requests := channel.snapshot()
	if !hasAttemptReason(requests, "failed", "system_failure") || !hasStepStatus(requests, "Service broken", "failed") {
		t.Fatalf("missing failed service lifecycle: %#v", requests)
	}
	if hasLogContent(requests, "service-super-secret") || !hasLogContent(requests, "[REDACTED]") {
		t.Fatal("service diagnostic was not safely redacted")
	}
	assertNoDockerResources(t, namespace)
}

func TestReconcileDockerPreservesActiveAndRemovesOrphans(t *testing.T) {
	if err := dockerReady(context.Background()); err != nil {
		t.Skip("Docker Engine is unavailable")
	}
	namespace := "test-reconcile-" + strconvTimestamp()
	cfg := config.Config{Executor: "docker", ResourceNamespace: namespace}
	active, orphan := "active-attempt", "orphan-attempt"
	activeVolume := "rbe-" + safeID(namespace) + "-active"
	orphanVolume := "rbe-" + safeID(namespace) + "-orphan"
	for _, resource := range []struct{ name, attempt string }{{activeVolume, active}, {orphanVolume, orphan}} {
		if _, err := dockerCommand(context.Background(), nil, "volume", "create", "--label", dockerAttemptLabel+"="+resource.attempt, "--label", dockerInstanceLabel+"="+namespace, resource.name); err != nil {
			t.Fatal(err)
		}
	}
	defer dockerCommand(context.Background(), nil, "volume", "rm", "--force", activeVolume, orphanVolume)
	if err := reconcileDocker(context.Background(), cfg, []string{active}); err != nil {
		t.Fatal(err)
	}
	if _, err := dockerCommand(context.Background(), nil, "volume", "inspect", activeVolume); err != nil {
		t.Fatal("active resource was removed")
	}
	if output, err := dockerCommand(context.Background(), nil, "volume", "inspect", orphanVolume); err == nil || !dockerMissing(err) {
		t.Fatalf("orphan resource was not removed: output=%q err=%v", output, err)
	}
}

func TestDockerErrorSanitization(t *testing.T) {
	err := &dockerCommandError{ExitCode: 125, Output: "failure secret"}
	if err.Error() != "Docker command failed with exit code 125" {
		t.Fatal(err.Error())
	}
	if got := safeDockerError(err, map[string]string{"TOKEN": "secret"}); got != "failure [REDACTED]" {
		t.Fatalf("unexpected sanitized error: %q", got)
	}
	if !dockerMissing(&dockerCommandError{ExitCode: 1, Output: "No such container"}) {
		t.Fatal("missing Docker resource was not recognized")
	}
}

func TestWriteDockerCopyArchiveNormalizesOwnership(t *testing.T) {
	source := t.TempDir()
	if err := os.MkdirAll(filepath.Join(source, "priv", "static"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "priv", "static", "app.css"), []byte("body {}"), 0o644); err != nil {
		t.Fatal(err)
	}

	var archive bytes.Buffer
	if err := writeDockerCopyArchive(&archive, source); err != nil {
		t.Fatal(err)
	}

	reader := tar.NewReader(bytes.NewReader(archive.Bytes()))
	entries := 0
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		entries++
		if header.Uid != 0 || header.Gid != 0 || header.Uname != "" || header.Gname != "" {
			t.Fatalf("archive entry %q retained host ownership: %d:%d %q:%q", header.Name, header.Uid, header.Gid, header.Uname, header.Gname)
		}
	}
	if entries != 3 {
		t.Fatalf("unexpected archive entry count: %d", entries)
	}
}

func TestDockerCopyTreeAllowsCapabilityDroppedJobToWrite(t *testing.T) {
	ctx := context.Background()
	if err := dockerReady(ctx); err != nil {
		t.Skip("Docker Engine is unavailable")
	}
	if err := acquireDockerImage(ctx, dockerReadinessImage); err != nil {
		t.Fatal(err)
	}

	suffix := strings.ToLower(safeID(t.Name())) + "-" + strconvTimestamp()
	container := "rbe-" + suffix
	volume := container + "-workspace"
	if _, err := dockerCommand(ctx, nil, "volume", "create", volume); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = dockerCommand(context.Background(), nil, "rm", "--force", container)
		_, _ = dockerCommand(context.Background(), nil, "volume", "rm", "--force", volume)
	})
	if _, err := dockerCommand(ctx, nil,
		"create", "--name", container,
		"--cap-drop", "ALL", "--security-opt", "no-new-privileges",
		"--mount", "type=volume,source="+volume+",target=/workspace",
		"--workdir", "/workspace",
		dockerReadinessImage, "sh", "-c", "while :; do sleep 3600; done",
	); err != nil {
		t.Fatal(err)
	}
	if _, err := dockerCommand(ctx, nil, "start", container); err != nil {
		t.Fatal(err)
	}

	source := t.TempDir()
	if err := os.MkdirAll(filepath.Join(source, "priv", "static"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "priv", "static", "app.css"), []byte("body {}"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := dockerCopyTree(ctx, source, container, "/workspace"); err != nil {
		t.Fatal(err)
	}

	output, err := dockerCommand(ctx, nil, "exec", container, "sh", "-c",
		"test \"$(stat -c '%u:%g' /workspace/priv/static)\" = '0:0' && mkdir -p /workspace/priv/static/assets && printf ok > /workspace/priv/static/assets/write-test",
	)
	if err != nil {
		t.Fatalf("capability-dropped job could not write copied source: %s: %v", output, err)
	}
}

func TestDockerExecutorCancelsAndTimesOutWithCleanup(t *testing.T) {
	if err := dockerReady(context.Background()); err != nil {
		t.Skip("Docker Engine is unavailable")
	}
	for _, testCase := range []struct {
		name       string
		timeoutMS  int64
		cancel     bool
		wantStatus string
		wantReason string
	}{
		{name: "cancel", timeoutMS: 30_000, cancel: true, wantStatus: "cancelled", wantReason: "cancelled"},
		{name: "timeout", timeoutMS: 2_000, wantStatus: "failed", wantReason: "timeout"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			namespace := "test-" + testCase.name + "-" + strconvTimestamp()
			cfg := config.Config{Executor: "docker", ResourceNamespace: namespace, CPUMillis: 1_000, MemoryBytes: 128 * 1024 * 1024, PIDsLimit: 64}
			defer reconcileDocker(context.Background(), cfg, nil)
			server := secretServer(t)
			defer server.Close()
			channel := &fakeRequester{notify: make(chan recordedRequest, 32)}
			executor := newConfiguredExecutor(cfg, channel, newTransferClient(configForTransfers(server.URL)))
			offer := testOffer(server.URL, []Step{{Name: "Wait", Kind: "run", Value: "sleep 30", Condition: "success"}})
			offer.Execution.Image = dockerReadinessImage
			offer.Execution.TimeoutMS = testCase.timeoutMS
			ctx, cancel := context.WithCancel(context.Background())
			done := make(chan error, 1)
			go func() { done <- executor.Run(ctx, offer) }()
			if testCase.cancel {
				deadline := time.After(30 * time.Second)
				for {
					select {
					case request := <-channel.notify:
						if request.event == "log_event" && request.payload["step_name"] == "Wait" && request.payload["status"] == "running" {
							cancel()
							goto wait
						}
					case <-deadline:
						t.Fatal("Docker command did not start")
					}
				}
			}
		wait:
			select {
			case err := <-done:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(30 * time.Second):
				t.Fatal("Docker execution did not terminate")
			}
			cancel()
			if !hasAttemptReason(channel.snapshot(), testCase.wantStatus, testCase.wantReason) {
				t.Fatalf("missing terminal outcome: %#v", channel.snapshot())
			}
			assertNoDockerResources(t, namespace)
		})
	}
}

func TestDockerExecutorPreparationHonorsAttemptTimeout(t *testing.T) {
	if err := dockerReady(context.Background()); err != nil {
		t.Skip("Docker Engine is unavailable")
	}
	namespace := "test-preparation-timeout-" + strconvTimestamp()
	cfg := config.Config{Executor: "docker", ResourceNamespace: namespace}
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/secrets" {
			timer := time.NewTimer(100 * time.Millisecond)
			defer timer.Stop()
			<-timer.C
			_, _ = io.WriteString(response, `{"secrets":{}}`)
			return
		}
		http.NotFound(response, request)
	}))
	defer server.Close()
	offer := testOffer(server.URL, []Step{{Name: "Never", Kind: "run", Value: "true", Condition: "success"}})
	offer.Execution.Image = dockerReadinessImage
	offer.Execution.TimeoutMS = 20
	channel := &fakeRequester{}
	executor := newConfiguredExecutor(cfg, channel, newTransferClient(configForTransfers(server.URL)))
	if err := executor.Run(context.Background(), offer); err != nil {
		t.Fatal(err)
	}
	if !hasAttemptReason(channel.snapshot(), "failed", "timeout") {
		t.Fatalf("preparation timeout was not reported: %#v", channel.snapshot())
	}
	assertNoDockerResources(t, namespace)
}

func TestDecodeDockerServicesRejectsUnsafeInput(t *testing.T) {
	valid, _ := json.Marshal(dockerService{ID: "database", Image: "postgres:18-alpine", SecretEnv: map[string]string{"PASSWORD": "DB_PASSWORD"}})
	if _, err := decodeDockerServices(map[string]json.RawMessage{"database": valid}, map[string]string{"DB_PASSWORD": "secret"}); err != nil {
		t.Fatal(err)
	}
	unsafe, _ := json.Marshal(dockerService{ID: "database", Image: "evil", Privileged: true})
	if _, err := decodeDockerServices(map[string]json.RawMessage{"database": unsafe}, nil); err == nil {
		t.Fatal("unsafe privileged service was accepted")
	}
	if _, err := decodeDockerServices(map[string]json.RawMessage{"database": valid}, nil); err == nil {
		t.Fatal("missing service secret was accepted")
	}
}

func configForTransfers(serverURL string) config.Config {
	return config.Config{ServerURL: serverURL, RunnerID: "runner-1", Credential: "runner-secret", Name: "docker-test"}
}

func assertNoDockerResources(t *testing.T, namespace string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		output, err := dockerCommand(context.Background(), nil, "ps", "--all", "--filter", "label="+dockerInstanceLabel+"="+namespace, "--format", "{{.Names}}")
		if err == nil && strings.TrimSpace(output) == "" {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("owned Docker resources remained after completion")
}

func strconvTimestamp() string {
	return time.Now().UTC().Format("150405.000000000")
}

func stringPointer(value string) *string {
	return &value
}
