# Robine native macOS runner

This module is the self-contained protocol-v1 runner used for trusted native macOS jobs. It intentionally keeps `CGO_ENABLED=0`: Xcode, Swift, signing, and notarization tools are child processes installed on the target Mac, not libraries linked into the runner.

## Verify

```sh
go test -race ./...
go test -coverprofile=cover.out ./...
go tool cover -func=cover.out
```

The repository gate requires at least 75% aggregate statement coverage for this module.

## Cross-compile

From the repository root:

```sh
ROBINE_GO="$(command -v go)" mix robine.macos_runner_release --output dist/runner-macos
```

This produces independently checksummed Darwin ARM64 and AMD64 Mach-O executables. After enrollment, use `rbe install --config /absolute/path/config.json --server https://ci.example.com`; the CLI validates the non-secret config identity and protocol connection before reconciling the user LaunchAgent. Full enrollment, launchd, diagnostic, and removal procedures are documented in `docs/runner-installation.md`.
