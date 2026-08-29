package runner

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/robine-ci/robine-runner/internal/config"
)

var (
	errCancellationRequested = errors.New("cancellation requested")
	errLeaseLost             = errors.New("attempt lease lost")
	errRunnerShutdown        = errors.New("runner shutting down")
	errAuthenticationFailure = errors.New("runner authentication failed")
	errRunnerRevoked         = fmt.Errorf("%w: credential was revoked", errAuthenticationFailure)
)

func AuthenticationFailure(err error) bool {
	return errors.Is(err, errAuthenticationFailure)
}

type application struct {
	config    config.Config
	client    requester
	transfers *transferClient

	mu          sync.Mutex
	executions  map[string]context.CancelCauseFunc
	executionWG sync.WaitGroup
	stopping    bool
	stopChannel context.CancelCauseFunc
}

func Run(ctx context.Context, cfg config.Config, version string) error {
	channelCtx, stopChannel := context.WithCancelCause(ctx)
	defer stopChannel(context.Canceled)
	app := &application{
		config:      cfg,
		transfers:   newTransferClient(cfg),
		executions:  make(map[string]context.CancelCauseFunc),
		stopChannel: stopChannel,
	}
	if config.Executor(cfg) == "docker" {
		if err := dockerReady(ctx); err != nil {
			return err
		}
		if err := reconcileDocker(ctx, cfg, nil); err != nil {
			return fmt.Errorf("reconcile Docker resources: %w", err)
		}
		go app.reconcileDockerLoop(ctx)
	}
	channel := newChannelClient(cfg, version, app)
	app.client = channel
	err := channel.Run(channelCtx)
	app.stopExecutions()
	app.waitForExecutions(10 * time.Second)
	if errors.Is(context.Cause(channelCtx), errRunnerRevoked) {
		return errRunnerRevoked
	}
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
		a.cancelAll(errCancellationRequested)
		if a.stopChannel != nil {
			a.stopChannel(errRunnerRevoked)
		}
	case "lease_lost":
		var input struct {
			AttemptID string `json:"attempt_id"`
		}
		if json.Unmarshal(payload, &input) == nil {
			a.cancelWith(input.AttemptID, errLeaseLost)
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
	if a.stopping {
		a.mu.Unlock()
		return
	}
	if _, exists := a.executions[offer.AttemptID]; exists || len(a.executions) >= 1 {
		a.mu.Unlock()
		if !exists {
			a.rejectOffer(ctx, offer, "runner_busy")
		}
		return
	}
	executionCtx, cancel := context.WithCancelCause(context.WithoutCancel(ctx))
	a.executions[offer.AttemptID] = cancel
	a.executionWG.Add(1)
	a.mu.Unlock()

	messageID, err := messageID()
	if err != nil {
		a.executionWG.Done()
		a.finish(offer.AttemptID)
		return
	}
	_, err = a.client.Request(executionCtx, "job_accept", map[string]any{
		"attempt_id":        offer.AttemptID,
		"idempotency_token": offer.IdempotencyToken,
		"message_id":        messageID,
	})
	if err != nil {
		a.executionWG.Done()
		a.finish(offer.AttemptID)
		log.Printf("job %s acceptance failed: %v", offer.AttemptID, err)
		return
	}

	go func() {
		defer a.executionWG.Done()
		defer a.finish(offer.AttemptID)
		executor := newConfiguredExecutor(a.config, a.client, a.transfers)
		if err := executor.Run(executionCtx, offer); err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("job %s failed: %v", offer.AttemptID, err)
		}
	}()
}

func (a *application) reconcileDockerLoop(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := reconcileDocker(ctx, a.config, a.ActiveAttemptIDs()); err != nil {
				log.Printf("Docker resource reconciliation failed")
			}
		}
	}
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
	a.cancelWith(attemptID, errCancellationRequested)
}

func (a *application) cancelWith(attemptID string, cause error) {
	a.mu.Lock()
	cancel := a.executions[attemptID]
	a.mu.Unlock()
	if cancel != nil {
		cancel(cause)
	}
}

func (a *application) cancelAll(cause error) {
	a.mu.Lock()
	cancels := make([]context.CancelCauseFunc, 0, len(a.executions))
	for _, cancel := range a.executions {
		cancels = append(cancels, cancel)
	}
	a.mu.Unlock()
	for _, cancel := range cancels {
		cancel(cause)
	}
}

func (a *application) stopExecutions() {
	a.mu.Lock()
	a.stopping = true
	cancels := make([]context.CancelCauseFunc, 0, len(a.executions))
	for _, cancel := range a.executions {
		cancels = append(cancels, cancel)
	}
	a.mu.Unlock()
	for _, cancel := range cancels {
		cancel(errRunnerShutdown)
	}
}

func (a *application) waitForExecutions(timeout time.Duration) {
	done := make(chan struct{})
	go func() {
		a.executionWG.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(timeout):
	}
}

func (a *application) finish(attemptID string) {
	a.mu.Lock()
	cancel := a.executions[attemptID]
	delete(a.executions, attemptID)
	a.mu.Unlock()
	if cancel != nil {
		cancel(context.Canceled)
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
