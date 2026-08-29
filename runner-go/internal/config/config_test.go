package config

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestParseCommandAndServerPolicy(t *testing.T) {
	t.Setenv("ROBINE_RUNNER_ENROLLMENT_TOKEN", "rbe_secret")
	command, err := ParseCommand([]string{"enroll", "--server", "https://ci.example.test", "--name", "mac-1", "--config", "runner.json"})
	if err != nil {
		t.Fatal(err)
	}
	if command.Kind != CommandEnroll || command.Enroll.EnrollmentToken != "rbe_secret" || !filepath.IsAbs(command.Enroll.ConfigPath) {
		t.Fatalf("unexpected command: %#v", command)
	}
	if os.Getenv("ROBINE_RUNNER_ENROLLMENT_TOKEN") != "" {
		t.Fatal("enrollment token remained in the environment")
	}
	for _, raw := range []string{"http://ci.example.test", "ftp://ci.example.test", "https://user@ci.example.test"} {
		if ValidateServerURL(raw) == nil {
			t.Fatalf("unsafe URL accepted: %s", raw)
		}
	}
	for _, raw := range []string{"https://ci.example.test", "http://localhost:4000", "http://127.0.0.1:4000"} {
		if err := ValidateServerURL(raw); err != nil {
			t.Fatalf("safe URL rejected: %s: %v", raw, err)
		}
	}
}

func TestWriteAndLoadPrivateConfig(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "private", "runner.json")
	cfg := Config{ServerURL: "https://ci.example.test", RunnerID: "runner-1", Credential: "secret", Name: "mac"}
	if err := Write(path, cfg, false); err != nil {
		t.Fatal(err)
	}
	loaded, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if loaded != cfg {
		t.Fatalf("loaded %#v, want %#v", loaded, cfg)
	}
	if runtime.GOOS != "windows" {
		info, _ := os.Stat(path)
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("config mode is %o", info.Mode().Perm())
		}
	}
	if err := Write(path, cfg, false); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("expected existing-file refusal, got %v", err)
	}
	if err := Write(path, cfg, true); err != nil {
		t.Fatalf("forced replacement failed: %v", err)
	}
	if runtime.GOOS != "windows" {
		if err := os.Chmod(path, 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := Load(path); err == nil {
			t.Fatal("insecure config permissions were accepted")
		}
	}
}

func TestParseCommandRejectsIncompleteInput(t *testing.T) {
	for _, args := range [][]string{{}, {"unknown"}, {"start"}, {"version", "extra"}, {"enroll", "--server", "https://ci.example.test"}} {
		if _, err := ParseCommand(args); err == nil {
			t.Fatalf("accepted invalid arguments: %#v", args)
		}
	}
}

func TestVersionStartAndInvalidConfig(t *testing.T) {
	version, err := ParseCommand([]string{"--version"})
	if err != nil || version.Kind != CommandVersion {
		t.Fatalf("version command failed: %#v %v", version, err)
	}
	start, err := ParseCommand([]string{"start", "--config", "runner.json"})
	if err != nil || start.Kind != CommandStart || !filepath.IsAbs(start.ConfigPath) {
		t.Fatalf("start command failed: %#v %v", start, err)
	}
	if err := Validate(Config{}); err == nil {
		t.Fatal("empty config was accepted")
	}
	path := filepath.Join(t.TempDir(), "invalid.json")
	if err := os.WriteFile(path, []byte("not-json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil {
		t.Fatal("invalid JSON config was accepted")
	}
	if err := Write(filepath.Join(t.TempDir(), "runner.json"), Config{}, false); err == nil {
		t.Fatal("invalid config was written")
	}
}

func TestParseInstallPreservesExplicitConfigPath(t *testing.T) {
	path := filepath.Join(t.TempDir(), "production-runner.json")
	command, err := ParseCommand([]string{"install", "--config", path, "--server", "https://ci.example.test/"})
	if err != nil {
		t.Fatal(err)
	}
	if command.Kind != CommandInstall || !command.Install.ConfigExplicit || command.Install.ConfigPath != path {
		t.Fatalf("explicit config path was not preserved: %#v", command)
	}
	if command.Install.ExpectedServerURL != "https://ci.example.test/" {
		t.Fatalf("unexpected expected server: %q", command.Install.ExpectedServerURL)
	}
	if !SameServer("https://CI.EXAMPLE.TEST", "https://ci.example.test/") {
		t.Fatal("equivalent server URLs did not match")
	}
}

func TestParseInstallRejectsRelativeConfig(t *testing.T) {
	if _, err := ParseCommand([]string{"install", "--config", "runner.json"}); err == nil {
		t.Fatal("relative install config was accepted")
	}
}
