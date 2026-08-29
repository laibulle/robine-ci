package service

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/robine-ci/robine-runner/internal/config"
)

type fakeSystemdCommands struct {
	active     bool
	restartErr bool
	expected   string
	pid        int
	processes  map[int]string
	calls      []string
}

func (f *fakeSystemdCommands) Run(_ context.Context, name string, args ...string) (string, error) {
	f.calls = append(f.calls, name+" "+strings.Join(args, " "))
	switch name {
	case "systemd-analyze":
		return "unit verified\n", nil
	case "systemctl":
		operation := ""
		for _, argument := range args {
			if argument == "daemon-reload" || argument == "enable" || argument == "restart" || argument == "show" || argument == "status" {
				operation = argument
				break
			}
		}
		switch operation {
		case "daemon-reload", "enable":
			return "", nil
		case "restart":
			if f.restartErr {
				return "Failed to connect to bus", errors.New("exit status 1")
			}
			f.active = true
			f.processes[f.pid] = f.expected
			return "", nil
		case "show":
			state := "inactive"
			pid := 0
			if f.active {
				state = "active"
				pid = f.pid
			}
			return fmt.Sprintf("ActiveState=%s\nMainPID=%d\n", state, pid), nil
		case "status":
			return "Active: failed", errors.New("exit status 3")
		}
	case "ps":
		if len(args) >= 2 && args[0] == "-p" {
			pid, _ := strconv.Atoi(args[1])
			command, ok := f.processes[pid]
			if !ok {
				return "", errors.New("exit status 1")
			}
			return command + "\n", nil
		}
		var output strings.Builder
		for pid, command := range f.processes {
			fmt.Fprintf(&output, "%d %s\n", pid, command)
		}
		return output.String(), nil
	case "kill":
		pid, _ := strconv.Atoi(args[len(args)-1])
		delete(f.processes, pid)
		return "", nil
	}
	return "", fmt.Errorf("unexpected command: %s %v", name, args)
}

func newSystemdHarness(t *testing.T, configPath, server string) (installHarness, *fakeSystemdCommands) {
	t.Helper()
	harness := newInstallHarness(t, configPath, server)
	commands := &fakeSystemdCommands{
		expected:  harness.commands.expected,
		pid:       5252,
		processes: make(map[int]string),
	}
	harness.installer.Platform = "linux"
	harness.installer.Commands = commands
	return harness, commands
}

func TestSystemdInstallPreservesConfigAndExcludesCredential(t *testing.T) {
	home := t.TempDir()
	configPath := filepath.Join(home, "production", "runner.json")
	harness, _ := newSystemdHarness(t, configPath, "https://ci.base59.dev")

	err := harness.installer.Install(context.Background(), config.InstallOptions{
		ConfigPath:        configPath,
		ConfigExplicit:    true,
		ExpectedServerURL: "https://ci.base59.dev",
	})
	if err != nil {
		t.Fatal(err)
	}
	unitPath := filepath.Join(harness.home, ".config", "systemd", "user", systemdUnitName)
	unit, err := os.ReadFile(unitPath)
	if err != nil {
		t.Fatal(err)
	}
	content := string(unit)
	if !strings.Contains(content, "ExecStart=\""+harness.binary+"\" start --config \""+configPath+"\"") {
		t.Fatalf("explicit config missing from systemd unit: %s", content)
	}
	if strings.Contains(content, harness.credential) || strings.Contains(harness.output.String(), harness.credential) {
		t.Fatal("runner credential leaked through systemd installation")
	}
	if strings.Contains(content, "sudo") || strings.Contains(content, "ROBINE_RUNNER_ENROLLMENT_TOKEN") {
		t.Fatalf("unsafe systemd unit: %s", content)
	}
	for _, name := range []string{"stdout.log", "stderr.log"} {
		info, err := os.Stat(filepath.Join(harness.home, ".local", "state", "robine-runner", name))
		if err != nil {
			t.Fatalf("private log %s was not prepared: %v", name, err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("private log %s has mode %v", name, info.Mode().Perm())
		}
	}
}

func TestSystemdInstallIsIdempotentAndStopsOnlyMatchingManualRunner(t *testing.T) {
	harness, commands := newSystemdHarness(t, "", "https://ci.base59.dev")
	commands.processes[1200] = commands.expected
	commands.processes[1300] = harness.binary + " start --config " + filepath.Join(harness.home, "other.json")
	options := config.InstallOptions{ExpectedServerURL: "https://ci.base59.dev"}

	if err := harness.installer.Install(context.Background(), options); err != nil {
		t.Fatal(err)
	}
	if err := harness.installer.Install(context.Background(), options); err != nil {
		t.Fatal(err)
	}
	calls := strings.Join(commands.calls, "\n")
	if strings.Count(calls, "systemctl --user restart "+systemdUnitName) != 2 {
		t.Fatalf("systemd unit was not restarted idempotently: %s", calls)
	}
	if !strings.Contains(calls, "kill -TERM 1200") || strings.Contains(calls, "kill -TERM 1300") {
		t.Fatalf("manual process safety policy violated: %s", calls)
	}
	if !strings.Contains(harness.output.String(), "Left different runner process PID 1300 unchanged") {
		t.Fatalf("different runner notice missing: %s", harness.output)
	}
}

func TestSystemdFailureReturnsBoundedSecretFreeDiagnostic(t *testing.T) {
	harness, commands := newSystemdHarness(t, "", "https://ci.base59.dev")
	commands.restartErr = true
	err := harness.installer.Install(context.Background(), config.InstallOptions{ExpectedServerURL: "https://ci.base59.dev"})
	if err == nil {
		t.Fatal("systemd restart failure was accepted")
	}
	message := err.Error()
	for _, expected := range []string{"Failed to connect to bus", "systemd-analyze verify", "binary:", "config:", "working directory:", "log directory:", "systemctl --user status"} {
		if !strings.Contains(message, expected) {
			t.Fatalf("diagnostic missing %q: %s", expected, message)
		}
	}
	if strings.Contains(message, harness.credential) {
		t.Fatal("systemd diagnostic leaked the credential")
	}
}
