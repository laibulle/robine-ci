package runner

import (
	"archive/tar"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/robine-ci/robine-runner/internal/config"
)

const (
	dockerAttemptLabel    = "io.robine.attempt"
	dockerInstanceLabel   = "io.robine.instance"
	dockerServiceLabel    = "io.robine.service"
	dockerDiagnosticLimit = 64 * 1024
	dockerReadinessImage  = "alpine@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce"
)

type dockerService struct {
	ID         string            `json:"id"`
	Image      string            `json:"image"`
	User       string            `json:"user"`
	Privileged bool              `json:"privileged"`
	Env        map[string]string `json:"env"`
	SecretEnv  map[string]string `json:"secret_env"`
	Command    []string          `json:"command"`
	Readiness  *dockerReadiness  `json:"readiness"`
}

type dockerReadiness struct {
	TCP       int   `json:"tcp"`
	TimeoutMS int64 `json:"timeout_ms"`
}

type dockerResources struct {
	container string
	volume    string
	network   string
	services  []string
}

type dockerCommandError struct {
	ExitCode int
	Output   string
}

func (e *dockerCommandError) Error() string {
	return fmt.Sprintf("Docker command failed with exit code %d", e.ExitCode)
}

func (e *executor) runDocker(ctx context.Context, offer Offer) error {
	timeout := time.Duration(offer.Execution.TimeoutMS) * time.Millisecond
	if timeout <= 0 || timeout > 24*time.Hour {
		timeout = 20 * time.Minute
	}
	executionCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	if err := dockerReady(executionCtx); err != nil {
		if executionCtx.Err() != nil {
			e.failDockerPreparationOutcome(ctx, offer, "Docker readiness timed out", contextOutcome(executionCtx))
			return nil
		}
		e.failDockerPreparation(ctx, offer, "Docker is unavailable")
		return err
	}
	root, err := os.MkdirTemp("", "robine-docker-"+safeID(offer.AttemptID)+"-")
	if err != nil {
		e.failDockerPreparation(ctx, offer, "Workspace preparation failed")
		return err
	}
	defer os.RemoveAll(root)
	if err := os.Chmod(root, 0o700); err != nil {
		e.failDockerPreparation(ctx, offer, "Workspace security failed")
		return err
	}

	secrets, err := e.downloadSecrets(executionCtx, offer.SecretsURL)
	if err != nil {
		if executionCtx.Err() != nil {
			e.failDockerPreparationOutcome(ctx, offer, "Secret transfer timed out", contextOutcome(executionCtx))
			return nil
		}
		e.failDockerPreparation(ctx, offer, "Secret transfer failed")
		return err
	}
	services, err := decodeDockerServices(offer.Execution.Services, secrets)
	if err != nil {
		e.failDockerPreparation(ctx, offer, "Service configuration is invalid")
		return err
	}
	resources := e.dockerResourceNames(offer.AttemptID, services)
	cleanupNeeded := false
	defer func() {
		if cleanupNeeded {
			cleanupCtx, stopCleanup := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
			defer stopCleanup()
			_ = e.cleanupDocker(cleanupCtx, resources)
		}
	}()

	if err := e.prepareDocker(executionCtx, offer, services, resources, root, secrets); err != nil {
		cleanupNeeded = true
		if executionCtx.Err() != nil {
			e.failDockerPreparationOutcome(ctx, offer, "Runner preparation timed out", contextOutcome(executionCtx))
			return nil
		}
		e.failDockerPreparation(ctx, offer, safeDockerError(err, secrets))
		return err
	}
	cleanupNeeded = true
	if err := attemptEvent(ctx, e.channel, offer, 2, "running", ""); err != nil {
		return err
	}

	outcome := e.runDockerSteps(executionCtx, offer, resources, services, secrets, root)

	cleanupCtx, stopCleanup := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
	cleanupErr := e.cleanupDocker(cleanupCtx, resources)
	stopCleanup()
	cleanupNeeded = false
	if cleanupErr != nil && outcome.status == "succeeded" {
		outcome = executionOutcome{status: "failed", reason: "system_failure"}
	}

	if !terminalDeliveryAllowed(ctx) {
		return nil
	}
	deliveryCtx, stopDelivery := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
	defer stopDelivery()
	return attemptEvent(deliveryCtx, e.channel, offer, 3, outcome.status, outcome.reason)
}

func dockerReady(ctx context.Context) error {
	checkCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	_, err := dockerCommand(checkCtx, nil, "version", "--format", "{{.Server.Version}}")
	if err != nil {
		return errors.New("Docker Engine is unavailable")
	}
	return nil
}

func (e *executor) prepareDocker(ctx context.Context, offer Offer, services []dockerService, resources dockerResources, root string, secrets map[string]string) error {
	images := []string{offer.Execution.Image}
	if len(services) > 0 {
		images = append(images, dockerReadinessImage)
	}
	for _, service := range services {
		images = append(images, service.Image)
	}
	for _, image := range uniqueStrings(images) {
		if err := acquireDockerImage(ctx, image); err != nil {
			return err
		}
	}
	if resources.network != "" {
		if _, err := dockerCommand(ctx, nil, append([]string{"network", "create"}, append(e.dockerLabels(offer.AttemptID), resources.network)...)...); err != nil {
			return err
		}
	}
	if _, err := dockerCommand(ctx, nil, append([]string{"volume", "create"}, append(e.dockerLabels(offer.AttemptID), resources.volume)...)...); err != nil {
		return err
	}
	for _, service := range services {
		name := resources.container + "-service-" + safeID(service.ID)
		if err := e.startDockerService(ctx, offer, service, name, resources.network, secrets); err != nil {
			return err
		}
	}
	if err := e.createDockerJob(ctx, offer, resources, secrets); err != nil {
		return err
	}
	if _, err := dockerCommand(ctx, nil, "start", resources.container); err != nil {
		return err
	}
	if err := e.copyDockerSource(ctx, offer, resources.container, root); err != nil {
		return err
	}
	if _, err := dockerCommand(ctx, nil, "exec", resources.container, offer.Execution.Shell, "-c", "true"); err != nil {
		return fmt.Errorf("configured shell is unavailable")
	}
	return nil
}

func acquireDockerImage(ctx context.Context, image string) error {
	if strings.TrimSpace(image) == "" {
		return errors.New("Docker image is empty")
	}
	inspectCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	_, err := dockerCommand(inspectCtx, nil, "image", "inspect", image)
	cancel()
	if err == nil {
		return nil
	}
	pullCtx, stopPull := context.WithTimeout(ctx, 5*time.Minute)
	defer stopPull()
	if _, err := dockerCommand(pullCtx, nil, "pull", image); err != nil {
		return fmt.Errorf("Docker image acquisition failed")
	}
	return nil
}

func (e *executor) createDockerJob(ctx context.Context, offer Offer, resources dockerResources, secrets map[string]string) error {
	args := []string{
		"create", "--name", resources.container,
		"--cap-drop", "ALL", "--security-opt", "no-new-privileges",
		"--cpus", cpuLimit(config.CPUMillis(e.config)),
		"--memory", strconv.FormatInt(config.MemoryBytes(e.config), 10),
		"--memory-swap", strconv.FormatInt(config.MemoryBytes(e.config), 10),
		"--pids-limit", strconv.FormatInt(config.PIDsLimit(e.config), 10),
		"--tmpfs", "/tmp:rw,exec,nosuid,size=1g",
		"--network", dockerNetwork(resources.network),
		"--mount", "type=volume,source=" + resources.volume + ",target=/workspace",
		"--workdir", "/workspace",
	}
	args = append(args, e.dockerLabels(offer.AttemptID)...)
	args = append(args, dockerEnvironmentArgs(jobEnvironment(offer.Execution, secrets))...)
	args = append(args, offer.Execution.Image, offer.Execution.Shell, "-c", "trap 'exit 0' TERM INT; while :; do sleep 3600; done")
	_, err := dockerCommand(ctx, nil, args...)
	return err
}

func (e *executor) startDockerService(ctx context.Context, offer Offer, service dockerService, name, network string, secrets map[string]string) error {
	started := time.Now()
	_ = e.sendLog(ctx, offer.AttemptID, 0, "Service "+service.ID, "success", "running", "system", nil, 0, "Starting service")
	args := []string{"create", "--name", name}
	args = append(args, e.dockerLabels(offer.AttemptID)...)
	args = append(args, "--label", dockerServiceLabel+"="+service.ID)
	if service.Privileged {
		args = append(args, "--privileged")
	} else {
		args = append(args, "--cap-drop", "ALL", "--security-opt", "no-new-privileges")
	}
	args = append(args,
		"--cpus", cpuLimit(config.CPUMillis(e.config)),
		"--memory", strconv.FormatInt(config.MemoryBytes(e.config), 10),
		"--memory-swap", strconv.FormatInt(config.MemoryBytes(e.config), 10),
		"--pids-limit", strconv.FormatInt(config.PIDsLimit(e.config), 10),
		"--tmpfs", "/tmp:rw,noexec,nosuid,size=1g",
		"--network", network, "--network-alias", service.ID,
	)
	if service.User != "" {
		args = append(args, "--user", service.User)
	}
	environment := cloneStrings(service.Env)
	for environmentName, secretName := range service.SecretEnv {
		environment[environmentName] = secrets[secretName]
	}
	args = append(args, dockerEnvironmentArgs(environment)...)
	args = append(args, service.Image)
	args = append(args, service.Command...)
	if _, err := dockerCommand(ctx, nil, args...); err != nil {
		return err
	}
	if _, err := dockerCommand(ctx, nil, "start", name); err != nil {
		return err
	}
	if err := e.awaitDockerService(ctx, service, name, network); err != nil {
		diagnostic := e.dockerServiceDiagnostic(ctx, name, secrets)
		_ = e.sendLog(context.WithoutCancel(ctx), offer.AttemptID, 0, "Service "+service.ID, "success", "failed", "system", 1, elapsedMS(started), diagnostic)
		return err
	}
	return e.sendLog(ctx, offer.AttemptID, 0, "Service "+service.ID, "success", "succeeded", "system", 0, elapsedMS(started), "Service ready")
}

func (e *executor) awaitDockerService(ctx context.Context, service dockerService, name, network string) error {
	timeout := int64(5_000)
	if service.Readiness != nil {
		timeout = service.Readiness.TimeoutMS
	}
	deadline := time.Now().Add(time.Duration(timeout) * time.Millisecond)
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		running, err := dockerContainerRunning(ctx, name)
		if err != nil || !running {
			return errors.New("service container exited before readiness")
		}
		if service.Readiness == nil {
			return nil
		}
		probeCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		_, probeErr := dockerCommand(probeCtx, nil,
			"run", "--rm", "--pull", "never", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
			"--network", network, dockerReadinessImage, "nc", "-z", "-w", "1", service.ID, strconv.Itoa(service.Readiness.TCP),
		)
		cancel()
		if probeErr == nil {
			return nil
		}
		timer := time.NewTimer(100 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
	return errors.New("service readiness timed out")
}

func (e *executor) copyDockerSource(ctx context.Context, offer Offer, container, root string) error {
	if offer.SourceURL == nil {
		return nil
	}
	body, _, status, err := e.transfers.get(ctx, *offer.SourceURL, "application/gzip")
	if err != nil || status != 200 {
		return errors.New("source transfer failed")
	}
	source := filepath.Join(root, "source")
	if err := os.Mkdir(source, 0o700); err != nil {
		return err
	}
	if err := extractArchive(body, source, true); err != nil {
		return err
	}
	return dockerCopyTree(ctx, source, container, "/workspace")
}

func (e *executor) runDockerSteps(ctx context.Context, offer Offer, resources dockerResources, services []dockerService, secrets map[string]string, root string) executionOutcome {
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
			_ = e.sendLog(ctx, offer.AttemptID, position, step.Name, condition, "skipped", "system", nil, 0, "")
			continue
		}
		if ctx.Err() != nil {
			return contextOutcome(ctx)
		}
		if !dockerServicesRunning(ctx, resources, services) {
			return executionOutcome{status: "failed", reason: "service_unavailable"}
		}
		var stepReason string
		switch step.Kind {
		case "run":
			stepReason = e.runDockerCommand(ctx, offer, resources.container, secrets, position, step, condition)
		case "builtin":
			stepReason = e.runDockerBuiltin(ctx, offer, resources.container, root, position, step, condition)
		default:
			stepReason = "command_failed"
		}
		if stepReason == "cancelled" || stepReason == "timeout" {
			status := "cancelled"
			if stepReason == "timeout" {
				status = "failed"
			}
			return executionOutcome{status: status, reason: stepReason}
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

func (e *executor) runDockerCommand(ctx context.Context, offer Offer, container string, secrets map[string]string, position int, step Step, condition string) string {
	started := time.Now()
	_ = e.sendLog(ctx, offer.AttemptID, position, step.Name, condition, "running", "system", nil, 0, "")
	args := []string{"exec", "--workdir", "/workspace"}
	args = append(args, dockerEnvironmentArgs(jobEnvironment(offer.Execution, secrets))...)
	args = append(args, container, offer.Execution.Shell, "-e", "-c", step.Value)
	cmd := exec.Command("docker", args...)
	configureProcess(cmd)
	writer := newLogWriter(ctx, e, offer.AttemptID, position, step.Name, condition, started, secrets)
	cmd.Stdout, cmd.Stderr = writer, writer
	if err := cmd.Start(); err != nil {
		_ = e.sendLog(ctx, offer.AttemptID, position, step.Name, condition, "failed", "system", nil, elapsedMS(started), "Docker exec failed to start")
		return "system_failure"
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	var commandErr error
	select {
	case commandErr = <-done:
	case <-ctx.Done():
		stopCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		_, _ = dockerCommand(stopCtx, nil, "stop", "--time", "5", container)
		cancel()
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		select {
		case commandErr = <-done:
		case <-time.After(2 * time.Second):
			commandErr = ctx.Err()
		}
	}
	writer.finish()
	if writer.err() != nil && ctx.Err() == nil {
		return "system_failure"
	}
	if ctx.Err() != nil {
		outcome := contextOutcome(ctx)
		_ = e.sendLog(context.WithoutCancel(ctx), offer.AttemptID, position, step.Name, condition, "cancelled", "system", nil, elapsedMS(started), "")
		return outcome.reason
	}
	code := exitCode(commandErr)
	status, reason := "succeeded", ""
	if commandErr != nil {
		status, reason = "failed", "command_failed"
	}
	_ = e.sendLog(ctx, offer.AttemptID, position, step.Name, condition, status, "system", code, elapsedMS(started), "")
	return reason
}

func (e *executor) runDockerBuiltin(ctx context.Context, offer Offer, container, root string, position int, step Step, condition string) string {
	started := time.Now()
	_ = e.sendLog(ctx, offer.AttemptID, position, step.Name, condition, "running", "system", nil, 0, "")
	workspace := filepath.Join(root, fmt.Sprintf("builtin-%d", position))
	_ = os.RemoveAll(workspace)
	if err := os.Mkdir(workspace, 0o700); err != nil {
		return "system_failure"
	}
	defer os.RemoveAll(workspace)

	var err error
	switch step.Value {
	case "artifacts/upload", "cache/save":
		paths, parseErr := stringList(step.With["paths"])
		if parseErr != nil {
			err = parseErr
			break
		}
		for _, path := range paths {
			if _, pathErr := workspacePath(workspace, path); pathErr != nil {
				err = pathErr
				break
			}
			destination := filepath.Join(workspace, filepath.Dir(path))
			if pathErr := os.MkdirAll(destination, 0o700); pathErr != nil {
				err = pathErr
				break
			}
			if _, pathErr := dockerCommand(ctx, nil, "cp", container+":/workspace/"+path, destination); pathErr != nil {
				err = pathErr
				break
			}
		}
		if err == nil {
			err = e.executeBuiltin(ctx, offer, workspace, step)
		}
	case "artifacts/download", "cache/restore":
		err = e.executeBuiltin(ctx, offer, workspace, step)
		if err == nil {
			err = dockerCopyTree(ctx, workspace, container, "/workspace")
		}
	default:
		err = errors.New("unsupported builtin")
	}
	if err != nil {
		_ = e.sendLog(ctx, offer.AttemptID, position, step.Name, condition, "failed", "system", 1, elapsedMS(started), safeLogError(err))
		return "command_failed"
	}
	_ = e.sendLog(ctx, offer.AttemptID, position, step.Name, condition, "succeeded", "system", 0, elapsedMS(started), "")
	return ""
}

func (e *executor) cleanupDocker(ctx context.Context, resources dockerResources) error {
	var failures []string
	names := []string{resources.container}
	for _, service := range resources.services {
		names = append(names, service)
	}
	for _, name := range names {
		if name == "" {
			continue
		}
		if _, err := dockerCommand(ctx, nil, "rm", "--force", "--volumes", name); err != nil && !dockerMissing(err) {
			failures = append(failures, "container")
		}
	}
	if resources.volume != "" {
		if _, err := dockerCommand(ctx, nil, "volume", "rm", "--force", resources.volume); err != nil && !dockerMissing(err) {
			failures = append(failures, "volume")
		}
	}
	if resources.network != "" {
		if _, err := dockerCommand(ctx, nil, "network", "rm", resources.network); err != nil && !dockerMissing(err) {
			failures = append(failures, "network")
		}
	}
	if len(failures) > 0 {
		return errors.New("Docker cleanup incomplete")
	}
	return nil
}

func (e *executor) dockerLabels(attemptID string) []string {
	return []string{"--label", dockerAttemptLabel + "=" + attemptID, "--label", dockerInstanceLabel + "=" + config.ResourceNamespace(e.config)}
}

func (e *executor) dockerServiceDiagnostic(ctx context.Context, name string, secrets map[string]string) string {
	output, err := dockerCommand(ctx, nil, "logs", "--tail", "200", name)
	if err != nil {
		if commandErr := new(dockerCommandError); errors.As(err, &commandErr) {
			output = commandErr.Output
		}
	}
	for _, secret := range secrets {
		if secret != "" {
			output = strings.ReplaceAll(output, secret, "[REDACTED]")
		}
	}
	if len(output) > dockerDiagnosticLimit {
		output = output[len(output)-dockerDiagnosticLimit:]
	}
	return output
}

func (e *executor) failDockerPreparation(ctx context.Context, offer Offer, message string) {
	e.failDockerPreparationOutcome(ctx, offer, message, executionOutcome{status: "failed", reason: "system_failure"})
}

func (e *executor) failDockerPreparationOutcome(ctx context.Context, offer Offer, message string, outcome executionOutcome) {
	if !terminalDeliveryAllowed(ctx) {
		return
	}
	deliveryCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
	defer cancel()
	_ = e.sendLog(deliveryCtx, offer.AttemptID, 0, "Runner preparation", "success", outcome.status, "system", 1, 0, message)
	_ = attemptEvent(deliveryCtx, e.channel, offer, 2, outcome.status, outcome.reason)
}

func dockerCommand(ctx context.Context, stdin io.Reader, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "docker", args...)
	cmd.Stdin = stdin
	output, err := cmd.CombinedOutput()
	if err == nil {
		return string(output), nil
	}
	exitCode := -1
	if exitError := new(exec.ExitError); errors.As(err, &exitError) {
		exitCode = exitError.ExitCode()
	}
	return "", &dockerCommandError{ExitCode: exitCode, Output: string(output)}
}

func dockerCopyTree(ctx context.Context, source, container, destination string) error {
	reader, writer := io.Pipe()
	archiveResult := make(chan error, 1)

	go func() {
		err := writeDockerCopyArchive(writer, source)
		_ = writer.CloseWithError(err)
		archiveResult <- err
	}()

	_, copyErr := dockerCommand(ctx, reader, "cp", "-", container+":"+destination)
	_ = reader.Close()
	archiveErr := <-archiveResult
	if archiveErr != nil {
		return archiveErr
	}
	return copyErr
}

func writeDockerCopyArchive(destination io.Writer, source string) error {
	writer := tar.NewWriter(destination)

	err := filepath.WalkDir(source, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path == source {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.IsDir() && !info.Mode().IsRegular() {
			return fmt.Errorf("Docker copy source contains unsupported entry %q", path)
		}
		header, err := tar.FileInfoHeader(info, "")
		if err != nil {
			return err
		}
		header.Name, err = filepath.Rel(source, path)
		if err != nil {
			return err
		}
		header.Name = filepath.ToSlash(header.Name)
		if info.IsDir() {
			header.Name += "/"
		}
		header.Uid, header.Gid = 0, 0
		header.Uname, header.Gname = "", ""
		header.ModTime = time.Unix(0, 0)
		header.AccessTime = time.Time{}
		header.ChangeTime = time.Time{}
		if err := writer.WriteHeader(header); err != nil {
			return err
		}
		if info.Mode().IsRegular() {
			file, err := os.Open(path)
			if err != nil {
				return err
			}
			_, copyErr := io.Copy(writer, file)
			closeErr := file.Close()
			if copyErr != nil {
				return copyErr
			}
			if closeErr != nil {
				return closeErr
			}
		}
		return nil
	})
	if err != nil {
		_ = writer.Close()
		return err
	}
	return writer.Close()
}

func decodeDockerServices(raw map[string]json.RawMessage, secrets map[string]string) ([]dockerService, error) {
	if len(raw) > 8 {
		return nil, errors.New("too many service containers")
	}
	ids := make([]string, 0, len(raw))
	for id := range raw {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	services := make([]dockerService, 0, len(ids))
	for _, id := range ids {
		var service dockerService
		if err := json.Unmarshal(raw[id], &service); err != nil {
			return nil, errors.New("invalid service configuration")
		}
		if service.ID != id || service.ID == "" || safeID(service.ID) != service.ID || service.Image == "" || len(service.Env) > 64 || len(service.SecretEnv) > 64 || len(service.Command) > 32 {
			return nil, errors.New("invalid service configuration")
		}
		if service.Privileged && (service.ID != "docker" || !strings.HasPrefix(service.Image, "docker:") || !strings.Contains(service.Image, "dind")) {
			return nil, errors.New("invalid privileged service")
		}
		for _, secretName := range service.SecretEnv {
			if _, ok := secrets[secretName]; !ok {
				return nil, errors.New("service secret is unavailable")
			}
		}
		if service.Readiness != nil && (service.Readiness.TCP < 1 || service.Readiness.TCP > 65535 || service.Readiness.TimeoutMS < 1_000 || service.Readiness.TimeoutMS > 120_000) {
			return nil, errors.New("invalid service readiness")
		}
		services = append(services, service)
	}
	return services, nil
}

func (e *executor) dockerResourceNames(attemptID string, services []dockerService) dockerResources {
	base := "rbe-" + safeID(config.ResourceNamespace(e.config)) + "-" + safeID(attemptID)
	resources := dockerResources{container: base, volume: base + "-workspace"}
	if len(services) > 0 {
		resources.network = base + "-network"
	}
	for _, service := range services {
		resources.services = append(resources.services, base+"-service-"+safeID(service.ID))
	}
	return resources
}

func dockerEnvironmentArgs(environment map[string]string) []string {
	keys := make([]string, 0, len(environment))
	for key := range environment {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	args := make([]string, 0, len(keys)*2)
	for _, key := range keys {
		args = append(args, "--env", key+"="+environment[key])
	}
	return args
}

func jobEnvironment(execution Execution, secrets map[string]string) map[string]string {
	values := cloneStrings(execution.Env)
	for key, value := range execution.BuildEnv {
		values[key] = value
	}
	for key, value := range secrets {
		values[key] = value
	}
	return values
}

func cloneStrings(input map[string]string) map[string]string {
	result := make(map[string]string, len(input))
	for key, value := range input {
		result[key] = value
	}
	return result
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]struct{})
	result := make([]string, 0, len(values))
	for _, value := range values {
		if _, ok := seen[value]; !ok {
			seen[value] = struct{}{}
			result = append(result, value)
		}
	}
	return result
}

func cpuLimit(millis int64) string {
	return fmt.Sprintf("%d.%03d", millis/1000, millis%1000)
}

func dockerNetwork(network string) string {
	if network == "" {
		return "bridge"
	}
	return network
}

func dockerContainerRunning(ctx context.Context, name string) (bool, error) {
	output, err := dockerCommand(ctx, nil, "inspect", "--format", "{{.State.Running}}", name)
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(output) == "true", nil
}

func dockerServicesRunning(ctx context.Context, resources dockerResources, services []dockerService) bool {
	for _, service := range services {
		running, err := dockerContainerRunning(ctx, resources.container+"-service-"+safeID(service.ID))
		if err != nil || !running {
			return false
		}
	}
	return true
}

func dockerMissing(err error) bool {
	commandErr := new(dockerCommandError)
	if !errors.As(err, &commandErr) {
		return false
	}
	output := strings.ToLower(commandErr.Output)
	return strings.Contains(output, "no such") || strings.Contains(output, "not found")
}

func safeDockerError(err error, secrets map[string]string) string {
	message := "Docker runner preparation failed"
	commandErr := new(dockerCommandError)
	if errors.As(err, &commandErr) {
		message = commandErr.Output
	} else if err != nil {
		message = err.Error()
	}
	for _, secret := range secrets {
		if secret != "" {
			message = strings.ReplaceAll(message, secret, "[REDACTED]")
		}
	}
	if len(message) > 4096 {
		message = message[:4096]
	}
	return message
}

func reconcileDocker(ctx context.Context, cfg config.Config, activeAttemptIDs []string) error {
	active := make(map[string]struct{}, len(activeAttemptIDs))
	for _, attemptID := range activeAttemptIDs {
		active[attemptID] = struct{}{}
	}
	filters := []string{"--filter", "label=" + dockerAttemptLabel, "--filter", "label=" + dockerInstanceLabel + "=" + config.ResourceNamespace(cfg)}
	type resourceSet struct {
		list   []string
		remove func(context.Context, string) error
	}
	sets := []resourceSet{
		{
			list: append([]string{"ps", "--all"}, append(filters, "--format", "{{.Names}} {{.Label \""+dockerAttemptLabel+"\"}}")...),
			remove: func(ctx context.Context, name string) error {
				_, err := dockerCommand(ctx, nil, "rm", "--force", "--volumes", name)
				return err
			},
		},
		{
			list: append([]string{"volume", "ls"}, append(filters, "--format", "{{.Name}} {{.Label \""+dockerAttemptLabel+"\"}}")...),
			remove: func(ctx context.Context, name string) error {
				_, err := dockerCommand(ctx, nil, "volume", "rm", "--force", name)
				return err
			},
		},
		{
			list: append([]string{"network", "ls"}, append(filters, "--format", "{{.Name}} {{.Label \""+dockerAttemptLabel+"\"}}")...),
			remove: func(ctx context.Context, name string) error {
				_, err := dockerCommand(ctx, nil, "network", "rm", name)
				return err
			},
		},
	}
	for _, set := range sets {
		output, err := dockerCommand(ctx, nil, set.list...)
		if err != nil {
			return err
		}
		for _, line := range strings.Split(strings.TrimSpace(output), "\n") {
			if strings.TrimSpace(line) == "" {
				continue
			}
			parts := strings.Fields(line)
			if len(parts) != 2 {
				return errors.New("invalid labeled Docker resource output")
			}
			if _, keep := active[parts[1]]; keep {
				continue
			}
			if err := set.remove(ctx, parts[0]); err != nil && !dockerMissing(err) {
				return err
			}
		}
	}
	return nil
}
