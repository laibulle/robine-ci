# Robine Go runner

This module is the self-contained protocol-v1 runner. It executes trusted native jobs on macOS and Windows and Docker jobs on Linux. The production server bundle runs the same Linux binary as its local Docker sidecar, so Phoenix never needs the Docker socket. It intentionally keeps `CGO_ENABLED=0`: platform toolchains and the Docker CLI are child processes, not libraries linked into the runner.

## Verify

```sh
CGO_ENABLED=0 go test -race ./...
CGO_ENABLED=0 go test -coverprofile=cover.out ./...
go tool cover -func=cover.out
```

Docker integration tests run when a Docker CLI and daemon are available. The repository gate requires them and at least 75% aggregate statement coverage.

## Cross-compile

From the repository root:

```sh
ROBINE_GO="$(command -v go)" mix robine.go_runner_release --output dist/runner-go
```

This produces independently checksummed Darwin, Linux, and Windows ARM64 and AMD64 executables. A Linux enrollment defaults to the Docker executor; the production sidecar passes it explicitly with resource and instance-namespace limits. After macOS enrollment, use `rbe install --config /absolute/path/config.json --server https://ci.example.com`; the CLI validates the non-secret config identity and protocol connection before reconciling the user LaunchAgent. Full remote enrollment and launchd procedures are documented in `docs/runner-installation.md`.
