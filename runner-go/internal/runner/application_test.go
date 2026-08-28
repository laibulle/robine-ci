package runner

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/robine-ci/robine-runner/internal/config"
)

func TestApplicationAcceptsAndCompletesOffer(t *testing.T) {
	server := secretServer(t)
	defer server.Close()
	client := &fakeRequester{notify: make(chan recordedRequest, 64)}
	app := &application{
		config:     config.Config{RunnerID: "runner", Credential: "secret"},
		client:     client,
		transfers:  newTransferClient(config.Config{RunnerID: "runner", Credential: "secret"}),
		executions: make(map[string]context.CancelFunc),
	}
	offer := testOffer(server.URL, []Step{{Name: "Build", Kind: "run", Value: "printf app", Condition: "success", With: map[string]any{}}})
	payload, _ := json.Marshal(offer)
	app.HandleEvent(context.Background(), "job_offer", payload)

	deadline := time.After(5 * time.Second)
	for {
		select {
		case request := <-client.notify:
			if request.event == "attempt_event" && request.payload["status"] == "succeeded" {
				for len(app.ActiveAttemptIDs()) != 0 {
					select {
					case <-time.After(time.Millisecond):
					case <-deadline:
						t.Fatalf("completed attempt remained active: %v", app.ActiveAttemptIDs())
					}
				}
				return
			}
		case <-deadline:
			t.Fatalf("offer did not complete: %#v", client.snapshot())
		}
	}
}

func TestApplicationCancellationBusyAndMalformedEvents(t *testing.T) {
	client := &fakeRequester{}
	app := &application{client: client, transfers: newTransferClient(config.Config{}), executions: make(map[string]context.CancelFunc)}
	cancelled := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	app.executions["active"] = func() { cancel(); close(cancelled) }
	if ids := app.ActiveAttemptIDs(); len(ids) != 1 || ids[0] != "active" {
		t.Fatalf("unexpected active IDs: %v", ids)
	}
	app.HandleHeartbeat(map[string]any{"cancellation_requested_attempt_ids": []any{"active"}})
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("heartbeat cancellation was ignored")
	}
	if ctx.Err() == nil {
		t.Fatal("active context was not cancelled")
	}

	app.executions = map[string]context.CancelFunc{"active": func() {}}
	busy := testOffer("http://localhost", []Step{{Name: "Build", Kind: "run", Value: "true"}})
	busy.AttemptID, busy.Execution.AttemptID = "busy", "busy"
	payload, _ := json.Marshal(busy)
	app.HandleEvent(context.Background(), "job_offer", payload)
	if len(client.snapshot()) != 1 || client.snapshot()[0].event != "job_reject" {
		t.Fatalf("busy offer was not rejected: %#v", client.snapshot())
	}
	app.HandleEvent(context.Background(), "job_offer", json.RawMessage(`{"bad":true}`))
	app.HandleEvent(context.Background(), "cancel", json.RawMessage(`{"attempt_id":"missing"}`))
	app.HandleEvent(context.Background(), "lease_lost", json.RawMessage(`{"attempt_id":"missing"}`))
	app.HandleEvent(context.Background(), "runner_revoked", json.RawMessage(`{}`))
	app.finish("active")
	if len(app.ActiveAttemptIDs()) != 0 {
		t.Fatal("finish did not remove active attempt")
	}
}

func TestValidOffer(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(response, `{}`) }))
	defer server.Close()
	offer := testOffer(server.URL, []Step{{Name: "Build", Kind: "run", Value: "true"}})
	if !validOffer(offer) {
		t.Fatal("valid offer rejected")
	}
	offer.BuiltinsURL = ""
	if validOffer(offer) {
		t.Fatal("invalid offer accepted")
	}
}
