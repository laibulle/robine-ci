package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/robine-ci/robine-runner/internal/config"
	"github.com/robine-ci/robine-runner/internal/runner"
	"github.com/robine-ci/robine-runner/internal/service"
)

var version = "dev"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "robine-runner:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	command, err := config.ParseCommand(args)
	if err != nil {
		return err
	}

	switch command.Kind {
	case config.CommandVersion:
		fmt.Printf("robine-runner %s\n", version)
		return nil
	case config.CommandEnroll:
		cfg, err := runner.Enroll(context.Background(), command.Enroll)
		if err != nil {
			return err
		}
		if err := config.Write(command.Enroll.ConfigPath, cfg, command.Enroll.Force); err != nil {
			return err
		}
		fmt.Printf("Runner enrolled as %s. Credential stored in %s.\n", cfg.RunnerID, command.Enroll.ConfigPath)
		return nil
	case config.CommandStart:
		cfg, err := config.Load(command.ConfigPath)
		if err != nil {
			return err
		}
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		return runner.Run(ctx, cfg, version)
	case config.CommandInstall:
		installer, err := service.NewInstaller(os.Stdout, func(ctx context.Context, cfg config.Config) error {
			probeCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
			defer cancel()
			return runner.Probe(probeCtx, cfg, version)
		})
		if err != nil {
			return err
		}
		ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		defer cancel()
		return installer.Install(ctx, command.Install)
	default:
		return fmt.Errorf("unsupported command")
	}
}
