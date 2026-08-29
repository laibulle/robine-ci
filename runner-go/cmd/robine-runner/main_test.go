package main

import (
	"path/filepath"
	"testing"
)

func TestRunVersionAndRejectInvalidCommands(t *testing.T) {
	previousVersion := version
	version = "test-version"
	defer func() { version = previousVersion }()
	if err := run([]string{"version"}); err != nil {
		t.Fatalf("version failed: %v", err)
	}
	if err := run([]string{"unknown"}); err == nil {
		t.Fatal("unknown command was accepted")
	}
	if err := run([]string{"start", "--config", filepath.Join(t.TempDir(), "missing.json")}); err == nil {
		t.Fatal("start accepted a missing config")
	}
}

func TestRunInstallRejectsAnUnavailableConfigOrPlatform(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing.json")
	if err := run([]string{"install", "--config", path}); err == nil {
		t.Fatal("install accepted an unavailable config or unsupported platform")
	}
}
