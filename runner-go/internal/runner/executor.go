package runner

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const maxOutputBytes = 10_000_000

var artifactNamePattern = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$`)

type executor struct {
	channel     requester
	transfers   *transferClient
	logSequence atomic.Int64
}

type executionOutcome struct {
	status string
	reason string
}

type requester interface {
	Request(context.Context, string, any) (map[string]any, error)
}

func newExecutor(channel requester, transfers *transferClient) *executor {
	return &executor{channel: channel, transfers: transfers}
}

func (e *executor) Run(ctx context.Context, offer Offer) error {
	root, err := os.MkdirTemp("", "robine-native-"+safeID(offer.AttemptID)+"-")
	if err != nil {
		e.failPreparation(ctx, offer)
		return fmt.Errorf("create attempt workspace: %w", err)
	}
	defer os.RemoveAll(root)
	if err := os.Chmod(root, 0o700); err != nil {
		e.failPreparation(ctx, offer)
		return fmt.Errorf("secure attempt workspace: %w", err)
	}
	workspace := filepath.Join(root, "workspace")
	if err := os.Mkdir(workspace, 0o700); err != nil {
		e.failPreparation(ctx, offer)
		return fmt.Errorf("create job workspace: %w", err)
	}

	if len(offer.Execution.Services) != 0 {
		e.failPreparation(ctx, offer)
		return errors.New("native service containers are unsupported")
	}
	if offer.SourceURL != nil {
		body, _, status, err := e.transfers.get(ctx, *offer.SourceURL, "application/gzip")
		if err != nil || status != http.StatusOK {
			e.failPreparation(ctx, offer)
			return fmt.Errorf("download source: HTTP %d: %w", status, err)
		}
		if err := extractArchive(body, workspace, true); err != nil {
			e.failPreparation(ctx, offer)
			return fmt.Errorf("extract source: %w", err)
		}
	}
	secrets, err := e.downloadSecrets(ctx, offer.SecretsURL)
	if err != nil {
		e.failPreparation(ctx, offer)
		return err
	}

	if err := attemptEvent(ctx, e.channel, offer, 2, "running", ""); err != nil {
		return err
	}
	timeout := time.Duration(offer.Execution.TimeoutMS) * time.Millisecond
	if timeout <= 0 || timeout > 24*time.Hour {
		timeout = 20 * time.Minute
	}
	executionCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	outcome := e.runSteps(executionCtx, offer, workspace, secrets)

	deliveryCtx, stopDelivery := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
	defer stopDelivery()
	if err := attemptEvent(deliveryCtx, e.channel, offer, 3, outcome.status, outcome.reason); err != nil {
		return err
	}
	return nil
}

func (e *executor) failPreparation(ctx context.Context, offer Offer) {
	deliveryCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
	defer cancel()
	_ = attemptEvent(deliveryCtx, e.channel, offer, 2, "failed", "system_failure")
}

func (e *executor) downloadSecrets(ctx context.Context, endpoint string) (map[string]string, error) {
	body, _, status, err := e.transfers.get(ctx, endpoint, "application/json")
	if err != nil || status != http.StatusOK {
		return nil, fmt.Errorf("download secrets: HTTP %d: %w", status, err)
	}
	var response struct {
		Secrets map[string]string `json:"secrets"`
	}
	if err := json.Unmarshal(body, &response); err != nil || response.Secrets == nil {
		return nil, errors.New("invalid secrets response")
	}
	return response.Secrets, nil
}

func (e *executor) runSteps(ctx context.Context, offer Offer, workspace string, secrets map[string]string) executionOutcome {
	failed := false
	reason := ""
	position := 0
	for _, step := range offer.Execution.Steps {
		if step.Kind == "builtin" && step.Value == "checkout" {
			continue
		}
		position++
		condition := step.Condition
		if condition == "" {
			condition = "success"
		}
		if !conditionMatches(condition, failed) {
			e.sendLog(ctx, offer.AttemptID, position, step.Name, condition, "skipped", "system", nil, 0, "")
			continue
		}
		if ctx.Err() != nil {
			return contextOutcome(ctx)
		}

		var stepReason string
		switch step.Kind {
		case "run":
			stepReason = e.runCommand(ctx, offer, workspace, secrets, position, step, condition)
		case "builtin":
			stepReason = e.runBuiltin(ctx, offer, workspace, position, step, condition)
		default:
			stepReason = "command_failed"
			e.sendLog(ctx, offer.AttemptID, position, step.Name, condition, "failed", "system", 1, 0, "unsupported step kind")
		}
		if stepReason == "cancelled" || stepReason == "timeout" {
			return executionOutcome{status: map[string]string{"cancelled": "cancelled", "timeout": "failed"}[stepReason], reason: stepReason}
		}
		if stepReason != "" {
			failed = true
			if reason == "" {
				reason = stepReason
			}
		}
	}
	if failed {
		return executionOutcome{status: "failed", reason: reason}
	}
	return executionOutcome{status: "succeeded"}
}

func (e *executor) runCommand(ctx context.Context, offer Offer, workspace string, secrets map[string]string, position int, step Step, condition string) string {
	started := time.Now()
	e.sendLog(ctx, offer.AttemptID, position, step.Name, condition, "running", "system", nil, 0, "")
	shell := offer.Execution.Shell
	if shell == "" {
		shell = "/bin/sh"
	}
	if shell != "/bin/sh" && shell != "/bin/bash" {
		e.sendLog(ctx, offer.AttemptID, position, step.Name, condition, "failed", "system", nil, elapsedMS(started), "unsupported shell")
		return "command_failed"
	}
	cmd := exec.Command(shell, "-e", "-c", step.Value)
	cmd.Dir = workspace
	cmd.Env = mergedEnvironment(offer.Execution, secrets)
	configureProcess(cmd)
	writer := newLogWriter(ctx, e, offer.AttemptID, position, step.Name, condition, started, secrets)
	cmd.Stdout, cmd.Stderr = writer, writer
	if err := cmd.Start(); err != nil {
		e.sendLog(ctx, offer.AttemptID, position, step.Name, condition, "failed", "system", nil, elapsedMS(started), "process start failed")
		return "command_failed"
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	var commandErr error
	select {
	case commandErr = <-done:
	case <-ctx.Done():
		terminateProcess(cmd)
		commandErr = <-done
	}
	writer.finish()
	if writer.err() != nil && ctx.Err() == nil {
		return "system_failure"
	}
	if ctx.Err() != nil {
		outcome := contextOutcome(ctx)
		status := "cancelled"
		if outcome.reason == "timeout" {
			status = "timed_out"
		}
		e.sendLog(context.WithoutCancel(ctx), offer.AttemptID, position, step.Name, condition, status, "system", nil, elapsedMS(started), "")
		return outcome.reason
	}
	code := exitCode(commandErr)
	status := "succeeded"
	reason := ""
	if commandErr != nil {
		status, reason = "failed", "command_failed"
	}
	e.sendLog(ctx, offer.AttemptID, position, step.Name, condition, status, "system", code, elapsedMS(started), "")
	return reason
}

func (e *executor) runBuiltin(ctx context.Context, offer Offer, workspace string, position int, step Step, condition string) string {
	started := time.Now()
	e.sendLog(ctx, offer.AttemptID, position, step.Name, condition, "running", "system", nil, 0, "")
	err := e.executeBuiltin(ctx, offer, workspace, step)
	if err != nil {
		e.sendLog(ctx, offer.AttemptID, position, step.Name, condition, "failed", "system", 1, elapsedMS(started), safeLogError(err))
		return "command_failed"
	}
	e.sendLog(ctx, offer.AttemptID, position, step.Name, condition, "succeeded", "system", 0, elapsedMS(started), "")
	return ""
}

func (e *executor) executeBuiltin(ctx context.Context, offer Offer, workspace string, step Step) error {
	switch step.Value {
	case "artifacts/upload", "cache/save":
		paths, err := stringList(step.With["paths"])
		if err != nil {
			return err
		}
		body, err := createArchive(workspace, paths)
		if err != nil {
			return err
		}
		if step.Value == "artifacts/upload" {
			name, err := resolvedArtifactName(step.With["name"])
			if err != nil {
				return err
			}
			days, err := integerOption(step.With["retention-days"], 7)
			if err != nil || days < 1 || days > 90 {
				return errors.New("invalid artifact retention")
			}
			return e.transfers.put(ctx, offer.BuiltinsURL+"/artifacts", url.Values{"name": {name}, "retention_days": {strconv.Itoa(days)}}, body)
		}
		key, ok := step.With["key"].(string)
		if !ok || key == "" {
			return errors.New("invalid cache key")
		}
		return e.transfers.put(ctx, offer.BuiltinsURL+"/cache", url.Values{"key": {key}}, body)
	case "artifacts/download", "cache/restore":
		endpoint := offer.BuiltinsURL + "/cache"
		query := url.Values{}
		destination := "."
		if step.Value == "artifacts/download" {
			endpoint = offer.BuiltinsURL + "/artifacts"
			name, nameOK := step.With["name"].(string)
			from, fromOK := step.With["from"].(string)
			if !nameOK || !fromOK || name == "" || from == "" {
				return errors.New("invalid artifact download")
			}
			query.Set("name", name)
			query.Set("from", from)
			if path, ok := step.With["path"].(string); ok && path != "" {
				destination = path
			}
		} else {
			key, ok := step.With["key"].(string)
			if !ok || key == "" {
				return errors.New("invalid cache key")
			}
			query.Set("key", key)
		}
		u, _ := url.Parse(endpoint)
		u.RawQuery = query.Encode()
		body, _, status, err := e.transfers.get(ctx, u.String(), "application/gzip")
		if err != nil {
			return err
		}
		if status == http.StatusNoContent && step.Value == "cache/restore" {
			return nil
		}
		if status != http.StatusOK {
			return fmt.Errorf("download failed with HTTP %d", status)
		}
		target, err := workspacePath(workspace, destination)
		if err != nil {
			return err
		}
		if err := rejectSymlinkComponents(workspace, destination); err != nil {
			return err
		}
		if err := os.MkdirAll(target, 0o755); err != nil {
			return err
		}
		return extractArchive(body, target, false)
	default:
		return fmt.Errorf("unsupported builtin %q", step.Value)
	}
}

type logWriter struct {
	mu          sync.Mutex
	ctx         context.Context
	executor    *executor
	attemptID   string
	position    int
	stepName    string
	condition   string
	started     time.Time
	redactor    *redactor
	written     int
	deliveryErr error
}

func newLogWriter(ctx context.Context, executor *executor, attemptID string, position int, stepName, condition string, started time.Time, secrets map[string]string) *logWriter {
	return &logWriter{ctx: ctx, executor: executor, attemptID: attemptID, position: position, stepName: stepName, condition: condition, started: started, redactor: newRedactor(secrets)}
}

func (w *logWriter) Write(input []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.deliveryErr != nil {
		return 0, w.deliveryErr
	}
	output := w.redactor.Push(input)
	w.deliver(output)
	if w.deliveryErr != nil {
		return 0, w.deliveryErr
	}
	return len(input), nil
}

func (w *logWriter) finish() {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.deliver(w.redactor.Finish())
}

func (w *logWriter) err() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.deliveryErr
}

func (w *logWriter) deliver(output []byte) {
	if len(output) == 0 || w.written >= maxOutputBytes {
		return
	}
	remaining := maxOutputBytes - w.written
	if len(output) > remaining {
		output = output[:remaining]
	}
	for len(output) > 0 {
		size := len(output)
		if size > 60_000 {
			size = 60_000
		}
		chunk := string(output[:size])
		if err := w.executor.sendLog(w.ctx, w.attemptID, w.position, w.stepName, w.condition, "running", "combined", nil, elapsedMS(w.started), chunk); err != nil {
			w.deliveryErr = err
			return
		}
		w.written += size
		output = output[size:]
	}
}

func (e *executor) sendLog(ctx context.Context, attemptID string, position int, name, condition, status, stream string, exitCode any, duration int64, content string) error {
	cursor := e.logSequence.Add(1)
	_, err := e.channel.Request(ctx, "log_event", map[string]any{
		"attempt_id":    attemptID,
		"sequence":      cursor,
		"step_position": position,
		"step_name":     name,
		"status":        status,
		"condition":     condition,
		"phase":         "execution",
		"stream":        stream,
		"exit_code":     exitCode,
		"duration_ms":   duration,
		"content":       content,
	})
	return err
}

func mergedEnvironment(execution Execution, secrets map[string]string) []string {
	values := make(map[string]string)
	for _, entry := range os.Environ() {
		if key, value, ok := strings.Cut(entry, "="); ok {
			values[key] = value
		}
	}
	for key, value := range execution.Env {
		values[key] = value
	}
	for key, value := range execution.BuildEnv {
		values[key] = value
	}
	for key, value := range secrets {
		values[key] = value
	}
	result := make([]string, 0, len(values))
	for key, value := range values {
		result = append(result, key+"="+value)
	}
	return result
}

func conditionMatches(condition string, failed bool) bool {
	switch condition {
	case "success":
		return !failed
	case "failure":
		return failed
	case "always":
		return true
	default:
		return false
	}
}

func contextOutcome(ctx context.Context) executionOutcome {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return executionOutcome{status: "failed", reason: "timeout"}
	}
	return executionOutcome{status: "cancelled", reason: "cancelled"}
}

func stringList(value any) ([]string, error) {
	raw, ok := value.([]any)
	if !ok || len(raw) == 0 {
		return nil, errors.New("paths must be a non-empty list")
	}
	result := make([]string, 0, len(raw))
	for _, entry := range raw {
		path, ok := entry.(string)
		if !ok || path == "" {
			return nil, errors.New("paths must contain strings")
		}
		result = append(result, path)
	}
	return result, nil
}

func integerOption(value any, fallback int) (int, error) {
	if value == nil {
		return fallback, nil
	}
	switch typed := value.(type) {
	case float64:
		if typed == float64(int(typed)) {
			return int(typed), nil
		}
	case int:
		return typed, nil
	}
	return 0, errors.New("option must be an integer")
}

func resolvedArtifactName(value any) (string, error) {
	name, ok := value.(string)
	if !ok {
		return "", errors.New("artifact name must be a string")
	}
	name = strings.ReplaceAll(name, "${{ runner.os }}", runtime.GOOS)
	name = strings.ReplaceAll(name, "${{ runner.arch }}", runtime.GOARCH)
	if strings.Contains(name, "${{") || !artifactNamePattern.MatchString(name) {
		return "", errors.New("invalid resolved artifact name")
	}
	return name, nil
}

func safeLogError(err error) string {
	if err == nil {
		return ""
	}
	text := err.Error()
	if len(text) > 4096 {
		text = text[:4096]
	}
	return text
}

func safeID(value string) string {
	return regexp.MustCompile(`[^a-zA-Z0-9_.-]`).ReplaceAllString(value, "-")
}

func elapsedMS(started time.Time) int64 { return time.Since(started).Milliseconds() }

var _ io.Writer = (*logWriter)(nil)
