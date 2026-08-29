package runner

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/robine-ci/robine-runner/internal/config"
)

type channelTestHandler struct {
	mu       sync.Mutex
	events   []string
	payloads []json.RawMessage
	notified chan struct{}
}

func (h *channelTestHandler) ActiveAttemptIDs() []string { return []string{"attempt-active"} }
func (h *channelTestHandler) HandleEvent(_ context.Context, event string, payload json.RawMessage) {
	h.mu.Lock()
	h.events = append(h.events, event)
	h.payloads = append(h.payloads, payload)
	h.mu.Unlock()
	select {
	case h.notified <- struct{}{}:
	default:
	}
}
func (h *channelTestHandler) HandleHeartbeat(map[string]any) {}

func TestChannelJoinsRequestsAndReceivesServerEvents(t *testing.T) {
	readyFile := filepath.Join(t.TempDir(), "ready")
	t.Setenv("ROBINE_RUNNER_READY_FILE", readyFile)
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/runner/socket/websocket" || request.Header.Get("X-Robine-Runner-Id") != "runner-1" || request.Header.Get("X-Robine-Runner-Credential") != "secret" {
			http.Error(response, "bad handshake", http.StatusUnauthorized)
			return
		}
		conn, err := upgrader.Upgrade(response, request, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		_, joinPayload, err := conn.ReadMessage()
		if err != nil {
			return
		}
		join, err := decodeFrame(joinPayload)
		if err != nil || join.Event != "phx_join" {
			t.Errorf("invalid join: %s %v", joinPayload, err)
			return
		}
		if !strings.Contains(string(join.Payload), "attempt-active") || !strings.Contains(string(join.Payload), `"native":true`) {
			t.Errorf("join missing capabilities: %s", join.Payload)
		}
		_ = conn.WriteJSON([]any{"1", "1", runnerTopic, "phx_reply", map[string]any{"status": "ok", "response": map[string]any{"protocol_version": 1}}})
		_ = conn.WriteJSON([]any{"1", nil, runnerTopic, "cancel", map[string]any{"attempt_id": "attempt-active"}})
		for {
			_, payload, err := conn.ReadMessage()
			if err != nil {
				return
			}
			frame, err := decodeFrame(payload)
			if err != nil {
				return
			}
			_ = conn.WriteJSON([]any{"1", frame.Reference, runnerTopic, "phx_reply", map[string]any{"status": "ok", "response": map[string]any{"echo": frame.Event}}})
		}
	}))
	defer server.Close()

	handler := &channelTestHandler{notified: make(chan struct{}, 1)}
	cfg := config.Config{ServerURL: server.URL, RunnerID: "runner-1", Credential: "secret", Name: "mac"}
	client := newChannelClient(cfg, "test", handler)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- client.Run(ctx) }()
	requestCtx, stop := context.WithTimeout(ctx, 5*time.Second)
	response, err := client.Request(requestCtx, "attempt_event", map[string]any{"sequence": 2})
	stop()
	if err != nil || response["echo"] != "attempt_event" {
		t.Fatalf("request failed: response=%v err=%v", response, err)
	}
	if body, err := os.ReadFile(readyFile); err != nil || string(body) != "ready\n" {
		t.Fatalf("readiness marker was not written: %q %v", body, err)
	}
	select {
	case <-handler.notified:
	case <-time.After(5 * time.Second):
		t.Fatal("server event was not delivered")
	}
	handler.mu.Lock()
	if len(handler.events) != 1 || handler.events[0] != "cancel" {
		t.Fatalf("unexpected events: %v", handler.events)
	}
	handler.mu.Unlock()
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("client did not stop after context cancellation")
	}
	if _, err := os.Stat(readyFile); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("readiness marker remained after disconnect: %v", err)
	}
}

func TestChannelHelpers(t *testing.T) {
	url, err := websocketURL("https://ci.example.test/base")
	if err != nil || url != "wss://ci.example.test/runner/socket/websocket?vsn=2.0.0" {
		t.Fatalf("unexpected websocket URL %q: %v", url, err)
	}
	if _, err := websocketURL("ftp://ci.example.test"); err == nil {
		t.Fatal("unsupported socket scheme accepted")
	}
	if _, err := decodeFrame([]byte(`{"bad":true}`)); err == nil {
		t.Fatal("invalid frame accepted")
	}
	for attempt := 1; attempt <= 20; attempt++ {
		delay := reconnectDelay(attempt)
		if delay < 0 || delay > 30*time.Second {
			t.Fatalf("invalid reconnect delay %s", delay)
		}
	}
	values := parseStringSlice([]any{"one", 2, "two", ""})
	if strings.Join(values, ",") != "one,two" {
		t.Fatalf("unexpected string list: %v", values)
	}
	facts := capabilities(config.Config{Executor: "native"})
	expectedOS := runtime.GOOS
	if expectedOS == "darwin" {
		expectedOS = "macos"
	}
	dockerFacts := capabilities(config.Config{Executor: "docker"})
	if dockerFacts["docker"] != true || dockerFacts["native"] != false || dockerFacts["executor"] != "docker" {
		t.Fatalf("unexpected Docker capabilities: %#v", dockerFacts)
	}
	if facts["os"] != expectedOS || facts["architecture"] != runtime.GOARCH || facts["docker"] != false || facts["native"] != true {
		t.Fatalf("unexpected capabilities: %v", facts)
	}
}

func TestChannelJoinReportsProtocolRejection(t *testing.T) {
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		conn, err := upgrader.Upgrade(response, request, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		_, _, _ = conn.ReadMessage()
		_ = conn.WriteJSON([]any{"1", "1", runnerTopic, "phx_reply", map[string]any{"status": "error", "response": map[string]any{"code": "incompatible_protocol"}}})
	}))
	defer server.Close()

	socketURL := "ws" + strings.TrimPrefix(server.URL, "http")
	conn, _, err := websocket.DefaultDialer.Dial(socketURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	client := newChannelClient(config.Config{RunnerID: "runner", Credential: "secret"}, "test", &channelTestHandler{})
	err = client.join(context.Background(), conn)
	_ = conn.Close()
	if err == nil || !strings.Contains(err.Error(), "incompatible_protocol") {
		t.Fatalf("unexpected join error: %v", err)
	}
}

func TestProbeClassifiesAuthenticationAndBadGateway(t *testing.T) {
	for status, expected := range map[int]string{
		http.StatusUnauthorized: "authentication failed",
		http.StatusBadGateway:   "HTTP 502",
	} {
		server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
			http.Error(response, http.StatusText(status), status)
		}))
		cfg := config.Config{ServerURL: server.URL, RunnerID: "runner-1", Credential: "secret", Name: "mac"}
		err := Probe(context.Background(), cfg, "test")
		server.Close()
		if err == nil || !strings.Contains(err.Error(), expected) {
			t.Fatalf("HTTP %d was not classified as %q: %v", status, expected, err)
		}
		if strings.Contains(err.Error(), cfg.Credential) {
			t.Fatal("probe error leaked the runner credential")
		}
		if status == http.StatusUnauthorized && !AuthenticationFailure(err) {
			t.Fatal("HTTP authentication failure was not marked permanent")
		}
	}
}

func TestChannelStopsRetryingAfterAuthenticationFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
	}))
	defer server.Close()
	client := newChannelClient(
		config.Config{ServerURL: server.URL, RunnerID: "runner-1", Credential: "secret", Name: "local"},
		"test",
		&channelTestHandler{},
	)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	err := client.Run(ctx)
	if !AuthenticationFailure(err) {
		t.Fatalf("authentication failure was retried: %v", err)
	}
}

func TestConnectionErrorsDistinguishDNSNetworkAndTLS(t *testing.T) {
	tests := []struct {
		err      error
		expected string
	}{
		{err: &net.DNSError{Err: "no such host", Name: "ci.invalid"}, expected: "DNS resolution failed"},
		{err: &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("connection refused")}, expected: "network connection failed"},
		{err: tls.RecordHeaderError{Msg: "bad TLS record"}, expected: "TLS validation failed"},
	}
	for _, test := range tests {
		if err := classifyNetworkError(test.err); !strings.Contains(err.Error(), test.expected) {
			t.Fatalf("%T was not classified as %q: %v", test.err, test.expected, err)
		}
	}
}
