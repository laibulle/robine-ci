package runner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"github.com/robine-ci/robine-runner/internal/config"
)

func TestEnrollAndAuthenticatedTransfers(t *testing.T) {
	artifact := []byte("artifact-content")
	digest := sha256.Sum256(artifact)
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api/v1/runners/enroll":
			body, _ := io.ReadAll(request.Body)
			if string(body) != `{"name":"mac","token":"rbe_token"}` {
				t.Errorf("unexpected enrollment body: %s", body)
			}
			response.WriteHeader(http.StatusCreated)
			_, _ = io.WriteString(response, `{"runner_id":"runner-1","credential":"runner-secret"}`)
		case "/download":
			assertRunnerHeaders(t, request)
			response.Header().Set("X-Content-Sha256", hex.EncodeToString(digest[:]))
			_, _ = response.Write(artifact)
		case "/upload":
			assertRunnerHeaders(t, request)
			if request.URL.Query().Get("name") != "app" {
				t.Errorf("missing upload query: %s", request.URL.RawQuery)
			}
			body, _ := io.ReadAll(request.Body)
			if string(body) != string(artifact) {
				t.Errorf("unexpected upload body: %q", body)
			}
			response.WriteHeader(http.StatusCreated)
			_, _ = io.WriteString(response, `{"digest":"`+hex.EncodeToString(digest[:])+`"}`)
		default:
			http.NotFound(response, request)
		}
	}))
	defer server.Close()

	cfg, err := Enroll(context.Background(), config.EnrollOptions{ServerURL: server.URL, Name: "mac", EnrollmentToken: "rbe_token"})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.RunnerID != "runner-1" || cfg.Credential != "runner-secret" {
		t.Fatalf("unexpected enrollment: %#v", cfg)
	}
	transfers := newTransferClient(cfg)
	body, _, status, err := transfers.get(context.Background(), server.URL+"/download", "application/gzip")
	if err != nil || status != http.StatusOK || string(body) != string(artifact) {
		t.Fatalf("download failed: status=%d body=%q err=%v", status, body, err)
	}
	if err := transfers.put(context.Background(), server.URL+"/upload", url.Values{"name": {"app"}}, artifact); err != nil {
		t.Fatal(err)
	}
}

func TestTransferRejectsDigestMismatchAndHTTPFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/bad-digest" {
			response.Header().Set("X-Content-Sha256", "00")
			_, _ = io.WriteString(response, "body")
			return
		}
		http.Error(response, "no", http.StatusServiceUnavailable)
	}))
	defer server.Close()
	client := newTransferClient(config.Config{RunnerID: "runner", Credential: "secret"})
	if _, _, _, err := client.get(context.Background(), server.URL+"/bad-digest", "application/gzip"); err == nil {
		t.Fatal("digest mismatch accepted")
	}
	if err := client.put(context.Background(), server.URL+"/failure", nil, []byte("body")); err == nil {
		t.Fatal("failed upload accepted")
	}
	if err := client.put(context.Background(), server.URL+"/failure", nil, make([]byte, maxUploadBytes+1)); err == nil {
		t.Fatal("oversized upload accepted")
	}
}

func TestEnrollRejectsInvalidResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(response, `{}`)
	}))
	defer server.Close()
	if _, err := Enroll(context.Background(), config.EnrollOptions{ServerURL: server.URL, Name: "mac", EnrollmentToken: "token"}); err == nil {
		t.Fatal("invalid enrollment response accepted")
	}
}

func assertRunnerHeaders(t *testing.T, request *http.Request) {
	t.Helper()
	if request.Header.Get("Authorization") != "Bearer runner-secret" || request.Header.Get("X-Robine-Runner-Id") != "runner-1" {
		t.Errorf("missing runner authentication headers: %v", request.Header)
	}
}
