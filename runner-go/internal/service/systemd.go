package service

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/robine-ci/robine-runner/internal/config"
)

const systemdUnitName = "robine-runner.service"

type systemdPaths struct {
	unitDir   string
	unit      string
	logDir    string
	stdoutLog string
	stderrLog string
}

func (i Installer) installSystemd(ctx context.Context, options config.InstallOptions) error {
	if i.Stdout == nil || i.Commands == nil || i.Probe == nil || i.Sleep == nil || i.VerifyConnectionLog == nil {
		return errors.New("systemd installer dependencies are incomplete")
	}
	configPath, cfg, err := i.loadConfiguration(ctx, options)
	if err != nil {
		return err
	}
	if err := validateInstallationPaths(i.BinaryPath, configPath, i.HomeDir); err != nil {
		return err
	}

	paths := i.systemdPaths()
	if err := prepareSystemdDirectories(paths); err != nil {
		return err
	}
	expectedCommand := i.BinaryPath + " start --config " + configPath
	if err := i.stopIdenticalManualProcesses(ctx, expectedCommand); err != nil {
		return err
	}
	logOffset, err := prepareSystemdLogs(paths)
	if err != nil {
		return err
	}

	unit := renderSystemdUnit(i.BinaryPath, configPath, i.HomeDir, paths)
	if strings.Contains(unit, cfg.Credential) {
		return errors.New("refusing to write a systemd unit containing the runner credential")
	}
	if err := i.writeValidatedSystemdUnit(ctx, paths.unit, unit); err != nil {
		return err
	}
	if output, err := i.Commands.Run(ctx, "systemctl", "--user", "daemon-reload"); err != nil {
		return fmt.Errorf("reload systemd user units: %w: %s\n%s", err, strings.TrimSpace(output), i.systemdDiagnostic(ctx, paths, configPath))
	}
	if output, err := i.Commands.Run(ctx, "systemctl", "--user", "enable", systemdUnitName); err != nil {
		return fmt.Errorf("enable systemd user unit: %w: %s\n%s", err, strings.TrimSpace(output), i.systemdDiagnostic(ctx, paths, configPath))
	}
	if output, err := i.Commands.Run(ctx, "systemctl", "--user", "restart", systemdUnitName); err != nil {
		return fmt.Errorf("restart systemd user unit: %w: %s\n%s", err, strings.TrimSpace(output), i.systemdDiagnostic(ctx, paths, configPath))
	}

	pid, err := i.waitForSystemdJob(ctx, expectedCommand)
	if err != nil {
		return fmt.Errorf("verify systemd user unit: %w\n%s", err, i.systemdDiagnostic(ctx, paths, configPath))
	}
	connectionCtx, cancel := context.WithTimeout(ctx, i.ConnectionTimeout)
	defer cancel()
	if err := i.VerifyConnectionLog(connectionCtx, paths.stderrLog, logOffset, pid); err != nil {
		return fmt.Errorf("runner process %d started but did not connect: %w", pid, err)
	}

	fmt.Fprintf(i.Stdout, "Installed and started %s with PID %d.\n", systemdUnitName, pid)
	fmt.Fprintln(i.Stdout, "Docker execution requires this user to have access to the Docker socket.")
	fmt.Fprintln(i.Stdout, "For operation after logout, configure user lingering according to the host policy.")
	return nil
}

func (i Installer) systemdPaths() systemdPaths {
	unitDir := filepath.Join(i.HomeDir, ".config", "systemd", "user")
	logDir := filepath.Join(i.HomeDir, ".local", "state", "robine-runner")
	return systemdPaths{
		unitDir:   unitDir,
		unit:      filepath.Join(unitDir, systemdUnitName),
		logDir:    logDir,
		stdoutLog: filepath.Join(logDir, "stdout.log"),
		stderrLog: filepath.Join(logDir, "stderr.log"),
	}
}

func prepareSystemdDirectories(paths systemdPaths) error {
	for _, path := range []string{paths.unitDir, paths.logDir} {
		if err := os.MkdirAll(path, 0o700); err != nil {
			return fmt.Errorf("create %s: %w", path, err)
		}
		if err := os.Chmod(path, 0o700); err != nil {
			return fmt.Errorf("secure %s: %w", path, err)
		}
	}
	return nil
}

func prepareSystemdLogs(paths systemdPaths) (int64, error) {
	launchdCompatible := installationPaths{
		logDir:    paths.logDir,
		stdoutLog: paths.stdoutLog,
		stderrLog: paths.stderrLog,
	}
	return prepareLogFiles(launchdCompatible)
}

func (i Installer) writeValidatedSystemdUnit(ctx context.Context, destination, body string) error {
	temporary, err := os.CreateTemp(filepath.Dir(destination), ".robine-runner.*.service")
	if err != nil {
		return fmt.Errorf("create temporary systemd unit: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return fmt.Errorf("secure temporary systemd unit: %w", err)
	}
	if _, err := io.WriteString(temporary, body); err != nil {
		temporary.Close()
		return fmt.Errorf("write systemd unit: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close systemd unit: %w", err)
	}
	if output, err := i.Commands.Run(ctx, "systemd-analyze", "verify", temporaryPath); err != nil {
		return fmt.Errorf("systemd unit validation failed: %w: %s", err, strings.TrimSpace(output))
	}
	if err := os.Rename(temporaryPath, destination); err != nil {
		return fmt.Errorf("install systemd unit: %w", err)
	}
	return nil
}

func (i Installer) waitForSystemdJob(ctx context.Context, expectedCommand string) (int, error) {
	for attempt := 0; attempt < 30; attempt++ {
		output, err := i.Commands.Run(ctx, "systemctl", "--user", "show", systemdUnitName, "--property=ActiveState", "--property=MainPID")
		if err == nil && systemdProperty(output, "ActiveState") == "active" {
			pid, parseErr := strconv.Atoi(systemdProperty(output, "MainPID"))
			if parseErr == nil && pid > 0 {
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
	return 0, errors.New("systemd did not report one active process with the requested binary and --config path")
}

func systemdProperty(output, key string) string {
	prefix := key + "="
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, prefix) {
			return strings.TrimPrefix(line, prefix)
		}
	}
	return ""
}

func (i Installer) systemdDiagnostic(ctx context.Context, paths systemdPaths, configPath string) string {
	var report strings.Builder
	report.WriteString("systemd user service diagnostic:\n")
	if output, err := i.Commands.Run(ctx, "systemd-analyze", "verify", paths.unit); err != nil {
		fmt.Fprintf(&report, "  systemd-analyze verify: error: %v: %s\n", err, bounded(output))
	} else {
		fmt.Fprintf(&report, "  systemd-analyze verify: %s\n", bounded(output))
	}
	for label, path := range map[string]string{
		"binary": i.BinaryPath, "config": configPath, "working directory": i.HomeDir,
		"unit directory": paths.unitDir, "log directory": paths.logDir,
	} {
		fmt.Fprintf(&report, "  %s: %s\n", label, describePath(path))
	}
	if output, err := i.Commands.Run(ctx, "systemctl", "--user", "status", systemdUnitName, "--no-pager"); err != nil {
		fmt.Fprintf(&report, "  systemctl --user status: error: %v: %s\n", err, bounded(output))
	} else {
		fmt.Fprintf(&report, "  systemctl --user status: %s\n", bounded(output))
	}
	return strings.TrimSpace(report.String())
}

func renderSystemdUnit(binary, configPath, home string, paths systemdPaths) string {
	return `[Unit]
Description=Robine CI Runner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=` + systemdQuote(binary) + ` start --config ` + systemdQuote(configPath) + `
WorkingDirectory=` + systemdQuote(home) + `
Environment="HOME=` + systemdEscape(home) + `"
Environment="PATH=` + systemdEscape(filepath.Join(home, ".local", "bin")+":/usr/local/bin:/usr/bin:/bin") + `"
UMask=0077
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
StandardOutput=append:` + systemdQuote(paths.stdoutLog) + `
StandardError=append:` + systemdQuote(paths.stderrLog) + `

[Install]
WantedBy=default.target
`
}

func systemdQuote(value string) string {
	return `"` + systemdEscape(value) + `"`
}

func systemdEscape(value string) string {
	value = strings.ReplaceAll(value, `\`, `\\`)
	value = strings.ReplaceAll(value, `"`, `\"`)
	value = strings.ReplaceAll(value, "%", "%%")
	value = strings.ReplaceAll(value, "\n", "")
	value = strings.ReplaceAll(value, "\r", "")
	return value
}
