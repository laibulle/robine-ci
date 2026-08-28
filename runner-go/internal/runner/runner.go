package runner

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sync"

	"github.com/robine-ci/robine-runner/internal/config"
)

type application struct {
	config    config.Config
	client    requester
	transfers *transferClient

	mu         sync.Mutex
	executions map[string]context.CancelFunc
}

func Run(ctx context.Context, cfg config.Config, version string) error {
	app := &application{
		config:     cfg,
		transfers:  newTransferClient(cfg),
		executions: make(map[string]context.CancelFunc),
	}
	channel := newChannelClient(cfg, version, app)
	app.client = channel
	err := channel.Run(ctx)
	app.cancelAll()
	if errors.Is(err, context.Canceled) {
		return nil
	}
	return err
}

func (a *application) ActiveAttemptIDs() []string {
	a.mu.Lock()
	defer a.mu.Unlock()
	ids := make([]string, 0, len(a.executions))
	for id := range a.executions {
		ids = append(ids, id)
	}
	return ids
}

func (a *application) HandleEvent(ctx context.Context, event string, payload json.RawMessage) {
	switch event {
	case "job_offer":
		var offer Offer
		if err := json.Unmarshal(payload, &offer); err != nil || !validOffer(offer) {
			log.Printf("rejected malformed job offer")
			return
		}
		a.acceptOffer(ctx, offer)
	case "cancel":
		var input struct {
			AttemptID string `json:"attempt_id"`
		}
		if json.Unmarshal(payload, &input) == nil {
			a.cancel(input.AttemptID)
		}
	case "runner_revoked":
		a.cancelAll()
	case "lease_lost":
		var input struct {
			AttemptID string `json:"attempt_id"`
		}
		if json.Unmarshal(payload, &input) == nil {
			a.cancel(input.AttemptID)
		}
	}
}

func (a *application) HandleHeartbeat(response map[string]any) {
	for _, attemptID := range parseStringSlice(response["cancellation_requested_attempt_ids"]) {
		a.cancel(attemptID)
	}
}

func (a *application) acceptOffer(ctx context.Context, offer Offer) {
	a.mu.Lock()
	if _, exists := a.executions[offer.AttemptID]; exists || len(a.executions) >= 1 {
		a.mu.Unlock()
		if !exists {
			a.rejectOffer(ctx, offer, "runner_busy")
		}
		return
	}
	executionCtx, cancel := context.WithCancel(ctx)
	a.executions[offer.AttemptID] = cancel
	a.mu.Unlock()

	messageID, err := messageID()
	if err != nil {
		a.finish(offer.AttemptID)
		return
	}
	_, err = a.client.Request(executionCtx, "job_accept", map[string]any{
		"attempt_id":        offer.AttemptID,
		"idempotency_token": offer.IdempotencyToken,
		"message_id":        messageID,
	})
	if err != nil {
		a.finish(offer.AttemptID)
		log.Printf("job %s acceptance failed: %v", offer.AttemptID, err)
		return
	}

	go func() {
		defer a.finish(offer.AttemptID)
		executor := newExecutor(a.client, a.transfers)
		if err := executor.Run(executionCtx, offer); err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("job %s failed: %v", offer.AttemptID, err)
		}
	}()
}

func (a *application) rejectOffer(ctx context.Context, offer Offer, reason string) {
	messageID, err := messageID()
	if err != nil {
		return
	}
	_, err = a.client.Request(ctx, "job_reject", map[string]any{
		"attempt_id":        offer.AttemptID,
		"idempotency_token": offer.IdempotencyToken,
		"message_id":        messageID,
		"reason":            reason,
	})
	if err != nil {
		log.Printf("job %s rejection failed: %v", offer.AttemptID, err)
	}
}

func (a *application) cancel(attemptID string) {
	a.mu.Lock()
	cancel := a.executions[attemptID]
	a.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (a *application) cancelAll() {
	a.mu.Lock()
	cancels := make([]context.CancelFunc, 0, len(a.executions))
	for _, cancel := range a.executions {
		cancels = append(cancels, cancel)
	}
	a.mu.Unlock()
	for _, cancel := range cancels {
		cancel()
	}
}

func (a *application) finish(attemptID string) {
	a.mu.Lock()
	cancel := a.executions[attemptID]
	delete(a.executions, attemptID)
	a.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func validOffer(offer Offer) bool {
	return offer.AttemptID != "" && offer.IdempotencyToken != "" &&
		offer.Execution.AttemptID == offer.AttemptID && offer.SecretsURL != "" &&
		offer.BuiltinsURL != "" && len(offer.Execution.Steps) > 0
}

func attemptEvent(ctx context.Context, client requester, offer Offer, sequence int, status, reason string) error {
	id, err := messageID()
	if err != nil {
		return err
	}
	payload := map[string]any{
		"attempt_id":        offer.AttemptID,
		"idempotency_token": offer.IdempotencyToken,
		"message_id":        id,
		"sequence":          sequence,
		"status":            status,
		"reason":            nil,
	}
	if reason != "" {
		payload["reason"] = reason
	}
	_, err = client.Request(ctx, "attempt_event", payload)
	if err != nil {
		return fmt.Errorf("deliver %s attempt event: %w", status, err)
	}
	return nil
}
