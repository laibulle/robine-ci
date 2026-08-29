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
	"time"

	"github.com/robine-ci/robine-runner/internal/config"
)

type fakeCommands struct {
	loaded       bool
	bootstrapErr bool
	expected     string
	launchPID    int
	processes    map[int]string
	calls        []string
}

func (f *fakeCommands) Run(_ context.Context, name string, args ...string) (string, error) {
	f.calls = append(f.calls, name+" "+strings.Join(args, " "))
	switch name {
	case "id":
		return "501\n", nil
	case "plutil":
		return args[len(args)-1] + ": OK\n", nil
	case "launchctl":
		switch args[0] {
		case "print":
			if !f.loaded {
				return "Bad request. Could not find service in domain for user gui: 501", errors.New("exit status 113")
			}
			return fmt.Sprintf("state = running\npid = %d\n", f.launchPID), nil
		case "bootout":
			f.loaded = false
			delete(f.processes, f.launchPID)
			return "", nil
		case "bootstrap":
			if f.bootstrapErr {
				return "Bootstrap failed: 5: Input/output error", errors.New("exit status 5")
			}
			f.loaded = true
			f.processes[f.launchPID] = f.expected
			return "", nil
		case "kickstart":
			return "", nil
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

type installHarness struct {
	home       string
	binary     string
	configPath string
	credential string
	output     *strings.Builder
	commands   *fakeCommands
	installer  Installer
}

func newInstallHarness(t *testing.T, configPath, server string) installHarness {
	t.Helper()
	home := t.TempDir()
	binary := filepath.Join(home, ".local", "bin", "rbe")
	if err := os.MkdirAll(filepath.Dir(binary), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(binary, []byte("runner"), 0o755); err != nil {
		t.Fatal(err)
	}
	if configPath == "" {
		configPath = filepath.Join(home, ".config", "robine-runner", "config.json")
	}
	credential := "rrc_never-write-this-secret"
	cfg := config.Config{ServerURL: server, RunnerID: "runner-1", Credential: credential, Name: "mac-production"}
	if err := config.Write(configPath, cfg, false); err != nil {
		t.Fatal(err)
	}
	expected := binary + " start --config " + configPath
	commands := &fakeCommands{expected: expected, launchPID: 4242, processes: make(map[int]string)}
	output := &strings.Builder{}
	installer := Installer{
		Platform:            "darwin",
		HomeDir:             home,
		BinaryPath:          binary,
		Stdout:              output,
		Commands:            commands,
		Probe:               func(context.Context, config.Config) error { return nil },
		Sleep:               func(time.Duration) {},
		ConnectionTimeout:   time.Second,
		VerifyConnectionLog: func(context.Context, string, int64, int) error { return nil },
	}
	return installHarness{home: home, binary: binary, configPath: configPath, credential: credential, output: output, commands: commands, installer: installer}
}

func TestInstallPreservesExplicitConfigAndExcludesSecrets(t *testing.T) {
	home := t.TempDir()
	configPath := filepath.Join(home, "production", "rbn-config.json")
	harness := newInstallHarness(t, configPath, "https://ci.base59.dev")

	if err := harness.installer.Install(context.Background(), config.InstallOptions{ConfigPath: configPath, ConfigExplicit: true, ExpectedServerURL: "https://ci.base59.dev/"}); err != nil {
		t.Fatal(err)
	}
	plistPath := filepath.Join(harness.home, "Library", "LaunchAgents", serviceLabel+".plist")
	plist, err := os.ReadFile(plistPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(plist), "<string>"+configPath+"</string>") {
		t.Fatalf("explicit config missing from plist: %s", plist)
	}
	if strings.Contains(string(plist), ".config/robine-runner/config.json") {
		t.Fatal("plist silently substituted the default config")
	}
	for _, content := range []string{string(plist), harness.output.String()} {
		if strings.Contains(content, harness.credential) {
			t.Fatal("runner credential leaked into installation output")
		}
	}
	for _, name := range []string{"stdout.log", "stderr.log"} {
		body, err := os.ReadFile(filepath.Join(harness.home, "Library", "Logs", "RobineRunner", name))
		if err != nil || strings.Contains(string(body), harness.credential) {
			t.Fatalf("secret present in %s: %q %v", name, body, err)
		}
	}
}

func TestInstallUsesValidDefaultConfigForExpectedServer(t *testing.T) {
	harness := newInstallHarness(t, "", "https://ci.base59.dev")
	if err := harness.installer.Install(context.Background(), config.InstallOptions{ExpectedServerURL: "https://ci.base59.dev"}); err != nil {
		t.Fatal(err)
	}
	plist, _ := os.ReadFile(filepath.Join(harness.home, "Library", "LaunchAgents", serviceLabel+".plist"))
	if !strings.Contains(string(plist), harness.configPath) || !strings.Contains(harness.output.String(), "server_url: https://ci.base59.dev") || !strings.Contains(harness.output.String(), "name: mac-production") {
		t.Fatalf("default config identity was not shown and retained: output=%s plist=%s", harness.output, plist)
	}
}

func TestInstallRefusesDefaultConfigForAnotherServer(t *testing.T) {
	harness := newInstallHarness(t, "", "https://ci-dev.base59.dev")
	err := harness.installer.Install(context.Background(), config.InstallOptions{ExpectedServerURL: "https://ci.base59.dev"})
	if err == nil || !strings.Contains(err.Error(), "belongs to https://ci-dev.base59.dev") {
		t.Fatalf("unexpected mismatch result: %v", err)
	}
	if len(harness.commands.calls) != 0 {
		t.Fatalf("launchd was touched after server mismatch: %v", harness.commands.calls)
	}
}

func TestInstallRefusesInvalidDefaultConfig(t *testing.T) {
	harness := newInstallHarness(t, "", "https://ci.base59.dev")
	if err := os.WriteFile(harness.configPath, []byte(`{"server_url":"https://ci.base59.dev","name":"incomplete"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	err := harness.installer.Install(context.Background(), config.InstallOptions{ExpectedServerURL: "https://ci.base59.dev"})
	if err == nil || !strings.Contains(err.Error(), "missing required values") {
		t.Fatalf("invalid default config was not refused: %v", err)
	}
	if len(harness.commands.calls) != 0 {
		t.Fatalf("launchd was touched for invalid config: %v", harness.commands.calls)
	}
}

func TestInstallReplacesAlreadyLoadedJobAndIsIdempotent(t *testing.T) {
	harness := newInstallHarness(t, "", "https://ci.base59.dev")
	harness.commands.loaded = true
	harness.commands.processes[harness.commands.launchPID] = harness.commands.expected
	options := config.InstallOptions{ExpectedServerURL: "https://ci.base59.dev"}
	if err := harness.installer.Install(context.Background(), options); err != nil {
		t.Fatal(err)
	}
	if err := harness.installer.Install(context.Background(), options); err != nil {
		t.Fatal(err)
	}
	calls := strings.Join(harness.commands.calls, "\n")
	if strings.Count(calls, "launchctl bootout gui/501/"+serviceLabel) != 2 || strings.Count(calls, "launchctl bootstrap gui/501 ") != 2 || strings.Count(calls, "launchctl kickstart -k gui/501/"+serviceLabel) != 2 {
		t.Fatalf("idempotent launchctl sequence missing: %s", calls)
	}
}

func TestInstallStopsIdenticalManualProcessButLeavesDifferentRunner(t *testing.T) {
	harness := newInstallHarness(t, "", "https://ci.base59.dev")
	harness.commands.processes[1200] = harness.commands.expected
	harness.commands.processes[1300] = harness.binary + " start --config " + filepath.Join(harness.home, "other.json")
	if err := harness.installer.Install(context.Background(), config.InstallOptions{ExpectedServerURL: "https://ci.base59.dev"}); err != nil {
		t.Fatal(err)
	}
	calls := strings.Join(harness.commands.calls, "\n")
	if !strings.Contains(calls, "kill -TERM 1200") || strings.Contains(calls, "kill -TERM 1300") {
		t.Fatalf("manual process safety policy violated: %s", calls)
	}
	if !strings.Contains(harness.output.String(), "Left different runner process PID 1300 unchanged") {
		t.Fatalf("different runner warning missing: %s", harness.output)
	}
}

func TestBootstrapFailureReturnsSafeDiagnostic(t *testing.T) {
	harness := newInstallHarness(t, "", "https://ci.base59.dev")
	harness.commands.bootstrapErr = true
	err := harness.installer.Install(context.Background(), config.InstallOptions{ExpectedServerURL: "https://ci.base59.dev"})
	if err == nil {
		t.Fatal("bootstrap failure was accepted")
	}
	message := err.Error()
	for _, expected := range []string{"Bootstrap failed: 5", "plutil -lint", "binary:", "config:", "working directory:", "log directory:", "launchctl print gui/501/" + serviceLabel, "do not retry with sudo"} {
		if !strings.Contains(message, expected) {
			t.Fatalf("diagnostic missing %q: %s", expected, message)
		}
	}
	if strings.Contains(message, harness.credential) {
		t.Fatal("bootstrap diagnostic leaked the credential")
	}
}

func TestInstallReportsConnectionFailureBeforeChangingLaunchd(t *testing.T) {
	harness := newInstallHarness(t, "", "https://ci.base59.dev")
	harness.installer.Probe = func(context.Context, config.Config) error {
		return errors.New("upstream returned HTTP 502 Bad Gateway")
	}
	err := harness.installer.Install(context.Background(), config.InstallOptions{ExpectedServerURL: "https://ci.base59.dev"})
	if err == nil || !strings.Contains(err.Error(), "HTTP 502") {
		t.Fatalf("connection failure was not classified: %v", err)
	}
	if len(harness.commands.calls) != 0 {
		t.Fatalf("launchd was touched after failed connection probe: %v", harness.commands.calls)
	}
}

func TestConnectionLogMustReportTheManagedPID(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stderr.log")
	if err := os.WriteFile(path, []byte("runner connected with protocol v1 as runner-1 pid=41\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	wrongCtx, cancelWrong := context.WithTimeout(context.Background(), time.Millisecond)
	defer cancelWrong()
	if err := verifyConnectionLog(wrongCtx, path, 0, 42); err == nil {
		t.Fatal("connection from another PID was accepted")
	}
	if err := verifyConnectionLog(context.Background(), path, 0, 41); err != nil {
		t.Fatalf("managed PID connection was not recognized: %v", err)
	}
}
