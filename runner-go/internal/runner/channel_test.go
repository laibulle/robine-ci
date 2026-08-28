package runner

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
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
}
