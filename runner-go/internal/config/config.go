package config

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

type Config struct {
	ServerURL  string `json:"server_url"`
	RunnerID   string `json:"runner_id"`
	Credential string `json:"credential"`
	Name       string `json:"name"`
}

type CommandKind uint8

const (
	CommandVersion CommandKind = iota + 1
	CommandEnroll
	CommandStart
)

type EnrollOptions struct {
	ServerURL       string
	Name            string
	ConfigPath      string
	EnrollmentToken string
	Force           bool
}

type Command struct {
	Kind       CommandKind
	ConfigPath string
	Enroll     EnrollOptions
}

func ParseCommand(args []string) (Command, error) {
	if len(args) == 0 {
		return Command{}, usageError()
	}

	switch args[0] {
	case "version", "--version":
		if len(args) != 1 {
			return Command{}, usageError()
		}
		return Command{Kind: CommandVersion}, nil
	case "enroll":
		set := flag.NewFlagSet("enroll", flag.ContinueOnError)
		set.SetOutput(os.Stderr)
		var options EnrollOptions
		set.StringVar(&options.ServerURL, "server", "", "Robine CI server URL")
		set.StringVar(&options.Name, "name", "", "runner name")
		set.StringVar(&options.ConfigPath, "config", "", "private config path")
		set.BoolVar(&options.Force, "force", false, "replace an existing config")
		if err := set.Parse(args[1:]); err != nil || set.NArg() != 0 {
			return Command{}, usageError()
		}
		options.EnrollmentToken = os.Getenv("ROBINE_RUNNER_ENROLLMENT_TOKEN")
		_ = os.Unsetenv("ROBINE_RUNNER_ENROLLMENT_TOKEN")
		if options.ServerURL == "" || options.Name == "" || options.ConfigPath == "" || options.EnrollmentToken == "" {
			return Command{}, errors.New("enroll requires --server, --name, --config, and ROBINE_RUNNER_ENROLLMENT_TOKEN")
		}
		if err := ValidateServerURL(options.ServerURL); err != nil {
			return Command{}, err
		}
		options.ConfigPath, _ = filepath.Abs(options.ConfigPath)
		return Command{Kind: CommandEnroll, Enroll: options}, nil
	case "start":
		set := flag.NewFlagSet("start", flag.ContinueOnError)
		set.SetOutput(os.Stderr)
		var path string
		set.StringVar(&path, "config", "", "private config path")
		if err := set.Parse(args[1:]); err != nil || set.NArg() != 0 || path == "" {
			return Command{}, usageError()
		}
		path, _ = filepath.Abs(path)
		return Command{Kind: CommandStart, ConfigPath: path}, nil
	default:
		return Command{}, usageError()
	}
}

func ValidateServerURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("invalid Robine CI server URL")
	}
	if u.Scheme == "https" {
		return nil
	}
	if u.Scheme == "http" && (u.Hostname() == "localhost" || u.Hostname() == "127.0.0.1" || u.Hostname() == "::1") {
		return nil
	}
	return errors.New("TLS is required except for a loopback server")
}

func Load(path string) (Config, error) {
	info, err := os.Stat(path)
	if err != nil {
		return Config{}, fmt.Errorf("load config: %w", err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0o077 != 0 {
		return Config{}, errors.New("runner config must not be accessible by group or others")
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read config: %w", err)
	}
	var cfg Config
	if err := json.Unmarshal(body, &cfg); err != nil {
		return Config{}, errors.New("runner config is not valid JSON")
	}
	if err := Validate(cfg); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func Validate(cfg Config) error {
	if strings.TrimSpace(cfg.RunnerID) == "" || strings.TrimSpace(cfg.Credential) == "" || strings.TrimSpace(cfg.Name) == "" {
		return errors.New("runner config is missing required values")
	}
	return ValidateServerURL(cfg.ServerURL)
}

func Write(path string, cfg Config, force bool) error {
	if err := Validate(cfg); err != nil {
		return err
	}
	if !force {
		if _, err := os.Lstat(path); err == nil {
			return errors.New("runner config already exists; pass --force to replace it")
		} else if !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("inspect config path: %w", err)
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("create config directory: %w", err)
	}
	body, err := json.Marshal(cfg)
	if err != nil {
		return fmt.Errorf("encode config: %w", err)
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".robine-runner-*.tmp")
	if err != nil {
		return fmt.Errorf("create temporary config: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return fmt.Errorf("secure temporary config: %w", err)
	}
	if _, err := tmp.Write(body); err != nil {
		tmp.Close()
		return fmt.Errorf("write temporary config: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("sync temporary config: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temporary config: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("install config: %w", err)
	}
	return nil
}

func usageError() error {
	return errors.New("usage: robine-runner version | enroll --server URL --name NAME --config PATH [--force] | start --config PATH")
}
