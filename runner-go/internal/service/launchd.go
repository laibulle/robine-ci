package service

import (
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/robine-ci/robine-runner/internal/config"
)

const serviceLabel = "com.robine.runner"

type ProbeFunc func(context.Context, config.Config) error

type commandRunner interface {
	Run(context.Context, string, ...string) (string, error)
}

type execCommandRunner struct{}

func (execCommandRunner) Run(ctx context.Context, name string, args ...string) (string, error) {
	output, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	return string(output), err
}

type Installer struct {
	Platform            string
	HomeDir             string
	BinaryPath          string
	Stdout              io.Writer
	Commands            commandRunner
	Probe               ProbeFunc
	Sleep               func(time.Duration)
	ConnectionTimeout   time.Duration
	VerifyConnectionLog func(context.Context, string, int64, int) error
}

func NewInstaller(stdout io.Writer, probe ProbeFunc) (Installer, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return Installer{}, fmt.Errorf("resolve runner home: %w", err)
	}
	binary, err := os.Executable()
	if err != nil {
		return Installer{}, fmt.Errorf("resolve runner executable: %w", err)
	}
	return Installer{
		Platform:            runtime.GOOS,
		HomeDir:             home,
		BinaryPath:          binary,
		Stdout:              stdout,
		Commands:            execCommandRunner{},
		Probe:               probe,
		Sleep:               time.Sleep,
		ConnectionTimeout:   15 * time.Second,
		VerifyConnectionLog: verifyConnectionLog,
	}, nil
}

func (i Installer) Install(ctx context.Context, options config.InstallOptions) error {
	switch i.Platform {
	case "darwin":
		return i.installLaunchd(ctx, options)
	case "linux":
		return i.installSystemd(ctx, options)
	default:
		return fmt.Errorf("service installation is unsupported on %s", i.Platform)
	}
}

func (i Installer) installLaunchd(ctx context.Context, options config.InstallOptions) error {
	if i.Stdout == nil || i.Commands == nil || i.Probe == nil || i.Sleep == nil || i.VerifyConnectionLog == nil {
		return errors.New("launchd installer dependencies are incomplete")
	}
	configPath, cfg, err := i.loadConfiguration(ctx, options)
	if err != nil {
		return err
	}

	paths := i.paths()
	if err := validateInstallationPaths(i.BinaryPath, configPath, i.HomeDir); err != nil {
		return err
	}
	if err := prepareDirectories(paths); err != nil {
		return err
	}
	domain, err := i.domain(ctx)
	if err != nil {
		return err
	}
	serviceTarget := domain + "/" + serviceLabel
	loaded, _, err := i.jobState(ctx, serviceTarget)
	if err != nil {
		return err
	}
	if loaded {
		if output, err := i.Commands.Run(ctx, "launchctl", "bootout", serviceTarget); err != nil {
			if !missingServiceOutput(output) {
				return fmt.Errorf("stop existing launchd job: %w: %s", err, strings.TrimSpace(output))
			}
		}
	}
	expectedCommand := i.BinaryPath + " start --config " + configPath
	if err := i.stopIdenticalManualProcesses(ctx, expectedCommand); err != nil {
		return err
	}
	logOffset, err := prepareLogFiles(paths)
	if err != nil {
		return err
	}

	plist := renderPlist(i.BinaryPath, configPath, i.HomeDir, paths.logDir)
	if strings.Contains(plist, cfg.Credential) {
		return errors.New("refusing to write a launchd plist containing the runner credential")
	}
	if err := i.writeValidatedPlist(ctx, paths.plist, plist); err != nil {
		return err
	}
	if output, err := i.Commands.Run(ctx, "launchctl", "bootstrap", domain, paths.plist); err != nil {
		diagnostic := i.diagnostic(ctx, domain, serviceTarget, paths, configPath)
		return fmt.Errorf("launchctl bootstrap failed: %w: %s\n%s", err, strings.TrimSpace(output), diagnostic)
	}
	if output, err := i.Commands.Run(ctx, "launchctl", "kickstart", "-k", serviceTarget); err != nil {
		diagnostic := i.diagnostic(ctx, domain, serviceTarget, paths, configPath)
		return fmt.Errorf("launchctl kickstart failed: %w: %s\n%s", err, strings.TrimSpace(output), diagnostic)
	}
	pid, err := i.waitForRunningJob(ctx, serviceTarget, expectedCommand)
	if err != nil {
		return fmt.Errorf("verify launchd job: %w\n%s", err, i.diagnostic(ctx, domain, serviceTarget, paths, configPath))
	}
	connectionCtx, cancel := context.WithTimeout(ctx, i.ConnectionTimeout)
	defer cancel()
	if err := i.VerifyConnectionLog(connectionCtx, paths.stderrLog, logOffset, pid); err != nil {
		return fmt.Errorf("runner process %d started but did not connect: %w", pid, err)
	}
	fmt.Fprintf(i.Stdout, "Installed and started %s with PID %d.\n", serviceLabel, pid)
	return nil
}

func (i Installer) loadConfiguration(ctx context.Context, options config.InstallOptions) (string, config.Config, error) {
	configPath := options.ConfigPath
	if !options.ConfigExplicit {
		configPath = filepath.Join(i.HomeDir, ".config", "robine-runner", "config.json")
	}
	if !filepath.IsAbs(configPath) {
		return "", config.Config{}, errors.New("runner config path must be absolute")
	}
	cfg, err := config.Load(configPath)
	if err != nil {
		return "", config.Config{}, fmt.Errorf("runner config %s is invalid: %w", configPath, err)
	}
	fmt.Fprintf(i.Stdout, "Runner configuration:\n  server_url: %s\n  name: %s\n  config: %s\n", cfg.ServerURL, cfg.Name, configPath)
	if options.ExpectedServerURL != "" && !config.SameServer(cfg.ServerURL, options.ExpectedServerURL) {
		return "", config.Config{}, fmt.Errorf("runner config belongs to %s, not requested server %s; pass --config with the intended runner configuration", cfg.ServerURL, options.ExpectedServerURL)
	}
	if !options.ConfigExplicit && options.ExpectedServerURL == "" {
		return "", config.Config{}, errors.New("refusing to install the default config without an expected server; pass --server or an explicit --config")
	}
	if err := i.Probe(ctx, cfg); err != nil {
		return "", config.Config{}, fmt.Errorf("runner connection check failed: %w", err)
	}
	return configPath, cfg, nil
}

type installationPaths struct {
	launchAgents string
	plist        string
	logDir       string
	stdoutLog    string
	stderrLog    string
}

func (i Installer) paths() installationPaths {
	launchAgents := filepath.Join(i.HomeDir, "Library", "LaunchAgents")
	logDir := filepath.Join(i.HomeDir, "Library", "Logs", "RobineRunner")
	return installationPaths{
		launchAgents: launchAgents,
		plist:        filepath.Join(launchAgents, serviceLabel+".plist"),
		logDir:       logDir,
		stdoutLog:    filepath.Join(logDir, "stdout.log"),
		stderrLog:    filepath.Join(logDir, "stderr.log"),
	}
}

func validateInstallationPaths(binary, configPath, workingDirectory string) error {
	for label, path := range map[string]string{"runner binary": binary, "runner config": configPath, "working directory": workingDirectory} {
		info, err := os.Stat(path)
		if err != nil {
			return fmt.Errorf("%s %s is unavailable: %w", label, path, err)
		}
		if label == "working directory" && !info.IsDir() {
			return fmt.Errorf("working directory %s is not a directory", path)
		}
		if label == "runner binary" && (!info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0) {
			return fmt.Errorf("runner binary %s is not an executable regular file", path)
		}
	}
	return nil
}

func prepareDirectories(paths installationPaths) error {
	for _, path := range []string{paths.launchAgents, paths.logDir} {
		if err := os.MkdirAll(path, 0o700); err != nil {
			return fmt.Errorf("create %s: %w", path, err)
		}
		if err := os.Chmod(path, 0o700); err != nil {
			return fmt.Errorf("secure %s: %w", path, err)
		}
	}
	return nil
}

func prepareLogFiles(paths installationPaths) (int64, error) {
	var stderrOffset int64
	for _, path := range []string{paths.stdoutLog, paths.stderrLog} {
		file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		if err != nil {
			return 0, fmt.Errorf("prepare runner log %s: %w", path, err)
		}
		if err := file.Chmod(0o600); err != nil {
			file.Close()
			return 0, fmt.Errorf("secure runner log %s: %w", path, err)
		}
		info, statErr := file.Stat()
		closeErr := file.Close()
		if statErr != nil {
			return 0, fmt.Errorf("inspect runner log %s: %w", path, statErr)
		}
		if closeErr != nil {
			return 0, fmt.Errorf("close runner log %s: %w", path, closeErr)
		}
		if path == paths.stderrLog {
			stderrOffset = info.Size()
		}
	}
	return stderrOffset, nil
}

func (i Installer) domain(ctx context.Context) (string, error) {
	output, err := i.Commands.Run(ctx, "id", "-u")
	if err != nil {
		return "", fmt.Errorf("resolve launchd user domain: %w", err)
	}
	uid := strings.TrimSpace(output)
	if _, err := strconv.Atoi(uid); err != nil || uid == "" {
		return "", errors.New("id -u returned an invalid user identifier")
	}
	return "gui/" + uid, nil
}

func (i Installer) jobState(ctx context.Context, serviceTarget string) (bool, string, error) {
	output, err := i.Commands.Run(ctx, "launchctl", "print", serviceTarget)
	if err == nil {
		return true, output, nil
	}
	if missingServiceOutput(output) {
		return false, output, nil
	}
	return false, output, fmt.Errorf("inspect launchd job: %w: %s", err, strings.TrimSpace(output))
}

func missingServiceOutput(output string) bool {
	lower := strings.ToLower(output)
	return strings.Contains(lower, "could not find service") || strings.Contains(lower, "service not found")
}

type process struct {
	pid     int
	command string
}

func (i Installer) processes(ctx context.Context) ([]process, error) {
	output, err := i.Commands.Run(ctx, "ps", "-axo", "pid=,command=", "-ww")
	if err != nil {
		return nil, fmt.Errorf("list runner processes: %w", err)
	}
	var result []process
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(strings.TrimSpace(line))
		if len(fields) < 2 {
			continue
		}
		pid, err := strconv.Atoi(fields[0])
		if err != nil {
			continue
		}
		command := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), fields[0]))
		result = append(result, process{pid: pid, command: command})
	}
	return result, nil
}

func (i Installer) stopIdenticalManualProcesses(ctx context.Context, expectedCommand string) error {
	processes, err := i.processes(ctx)
	if err != nil {
		return err
	}
	for _, process := range processes {
		if process.command == expectedCommand {
			if output, err := i.Commands.Run(ctx, "kill", "-TERM", strconv.Itoa(process.pid)); err != nil {
				return fmt.Errorf("stop duplicate manual runner PID %d: %w: %s", process.pid, err, strings.TrimSpace(output))
			}
			fmt.Fprintf(i.Stdout, "Stopped identical manually started runner PID %d.\n", process.pid)
		} else if strings.HasPrefix(process.command, i.BinaryPath+" start --config ") {
			fmt.Fprintf(i.Stdout, "Left different runner process PID %d unchanged.\n", process.pid)
		}
	}
	for attempt := 0; attempt < 20; attempt++ {
		remaining, err := i.processes(ctx)
		if err != nil {
			return err
		}
		duplicate := false
		for _, process := range remaining {
			if process.command == expectedCommand {
				duplicate = true
				break
			}
		}
		if !duplicate {
			return nil
		}
		i.Sleep(100 * time.Millisecond)
	}
	return errors.New("identical manual runner did not stop after SIGTERM")
}

func (i Installer) writeValidatedPlist(ctx context.Context, destination, body string) error {
	temporary, err := os.CreateTemp(filepath.Dir(destination), ".com.robine.runner.*.plist")
	if err != nil {
		return fmt.Errorf("create temporary launchd plist: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return fmt.Errorf("secure temporary launchd plist: %w", err)
	}
	if _, err := io.WriteString(temporary, body); err != nil {
		temporary.Close()
		return fmt.Errorf("write launchd plist: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close launchd plist: %w", err)
	}
	if output, err := i.Commands.Run(ctx, "plutil", "-lint", temporaryPath); err != nil {
		return fmt.Errorf("launchd plist validation failed: %w: %s", err, strings.TrimSpace(output))
	}
	if err := os.Rename(temporaryPath, destination); err != nil {
		return fmt.Errorf("install launchd plist: %w", err)
	}
	return nil
}

var statePattern = regexp.MustCompile(`(?m)^\s*state\s*=\s*([^\s]+)\s*$`)
var pidPattern = regexp.MustCompile(`(?m)^\s*pid\s*=\s*([0-9]+)\s*$`)

func (i Installer) waitForRunningJob(ctx context.Context, serviceTarget, expectedCommand string) (int, error) {
	for attempt := 0; attempt < 30; attempt++ {
		loaded, output, err := i.jobState(ctx, serviceTarget)
		if err != nil {
			return 0, err
		}
		if loaded && capture(statePattern, output) == "running" {
			pid, err := strconv.Atoi(capture(pidPattern, output))
			if err == nil && pid > 0 {
				processOutput, processErr := i.Commands.Run(ctx, "ps", "-p", strconv.Itoa(pid), "-o", "command=", "-ww")
				if processErr == nil && strings.TrimSpace(processOutput) == expectedCommand {
					processes, listErr := i.processes(ctx)
					if listErr != nil {
						return 0, listErr
					}
					count := 0
					for _, process := range processes {
						if process.command == expectedCommand {
							count++
						}
					}
					if count == 1 {
						return pid, nil
					}
				}
			}
		}
		i.Sleep(100 * time.Millisecond)
	}
	return 0, errors.New("launchd did not report one running process with the requested binary and --config path")
}

func capture(pattern *regexp.Regexp, input string) string {
	match := pattern.FindStringSubmatch(input)
	if len(match) != 2 {
		return ""
	}
	return match[1]
}

func (i Installer) diagnostic(ctx context.Context, domain, serviceTarget string, paths installationPaths, configPath string) string {
	var report strings.Builder
	report.WriteString("launchd diagnostic (user LaunchAgent; do not retry with sudo):\n")
	if output, err := i.Commands.Run(ctx, "plutil", "-lint", paths.plist); err != nil {
		fmt.Fprintf(&report, "  plutil -lint: error: %v: %s\n", err, strings.TrimSpace(output))
	} else {
		fmt.Fprintf(&report, "  plutil -lint: %s\n", strings.TrimSpace(output))
	}
	for label, path := range map[string]string{
		"binary": i.BinaryPath, "config": configPath, "working directory": i.HomeDir,
		"launch agents": paths.launchAgents, "log directory": paths.logDir,
	} {
		fmt.Fprintf(&report, "  %s: %s\n", label, describePath(path))
	}
	if output, err := i.Commands.Run(ctx, "launchctl", "print", serviceTarget); err != nil {
		fmt.Fprintf(&report, "  launchctl print %s: error: %v: %s\n", serviceTarget, err, bounded(output))
	} else {
		fmt.Fprintf(&report, "  launchctl print %s: %s\n", serviceTarget, bounded(output))
	}
	fmt.Fprintf(&report, "  bootstrap domain: %s\n", domain)
	return strings.TrimSpace(report.String())
}

func describePath(path string) string {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Sprintf("%s (error: %v)", path, err)
	}
	return fmt.Sprintf("%s (mode=%04o directory=%t regular=%t)", path, info.Mode().Perm(), info.IsDir(), info.Mode().IsRegular())
}

func bounded(value string) string {
	value = strings.TrimSpace(value)
	if len(value) > 4096 {
		return value[:4096] + "…"
	}
	return value
}

func renderPlist(binary, configPath, home, logDir string) string {
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>` + xmlEscape(serviceLabel) + `</string>
    <key>ProgramArguments</key>
    <array>
      <string>` + xmlEscape(binary) + `</string>
      <string>start</string>
      <string>--config</string>
      <string>` + xmlEscape(configPath) + `</string>
    </array>
    <key>WorkingDirectory</key>
    <string>` + xmlEscape(home) + `</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>HOME</key>
      <string>` + xmlEscape(home) + `</string>
      <key>PATH</key>
      <string>` + xmlEscape(filepath.Join(home, ".cargo", "bin")+":"+filepath.Join(home, ".local", "bin")+":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin") + `</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
      <key>SuccessfulExit</key>
      <false/>
    </dict>
    <key>ProcessType</key>
    <string>Background</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>` + xmlEscape(filepath.Join(logDir, "stdout.log")) + `</string>
    <key>StandardErrorPath</key>
    <string>` + xmlEscape(filepath.Join(logDir, "stderr.log")) + `</string>
  </dict>
</plist>
`
}

func xmlEscape(value string) string {
	var output strings.Builder
	_ = xml.EscapeText(&output, []byte(value))
	return output.String()
}

func verifyConnectionLog(ctx context.Context, path string, offset int64, pid int) error {
	for {
		body, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("read runner log: %w", err)
		}
		if offset < 0 || offset > int64(len(body)) {
			offset = 0
		}
		newOutput := string(body[offset:])
		for _, line := range strings.Split(newOutput, "\n") {
			if strings.Contains(line, "runner connected with protocol v1 as ") && strings.Contains(line, fmt.Sprintf("pid=%d", pid)) {
				return nil
			}
		}
		for _, marker := range []string{"DNS resolution failed", "network connection failed", "TLS validation failed", "upstream returned HTTP 502", "authentication failed"} {
			if strings.Contains(newOutput, marker) {
				return errors.New(marker)
			}
		}
		select {
		case <-ctx.Done():
			return errors.New("timed out waiting for a protocol v1 connection; inspect the runner stderr log")
		case <-time.After(100 * time.Millisecond):
		}
	}
}
