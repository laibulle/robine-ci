# RUN-005 — Cross-platform runner installation

## Status

- **State:** Accepted
- **Owner:** Execution
- **Target:** Post-MVP
- **Last updated:** 2026-08-29

## Summary

Robine exposes one transparent installation surface that selects and verifies the released `rbe` binary for macOS, Linux, or Windows and guides the operator into a durable least-privilege service configuration.

## Problem

The released runner already targets three operating systems, but the public installer and administration copy describe only macOS. Linux operators cannot use the same safe enrollment journey, Windows operators have no native download command, and a platform mismatch fails only after copying a Mac-specific command.

## Goals

- Select the exact released binary from operating-system and architecture facts.
- Verify the GitHub Release SHA-256 digest before atomic installation.
- Reconcile durable unprivileged services on macOS and Linux.
- Keep enrollment credentials out of scripts, service definitions, arguments, logs, and Git.
- Present copyable POSIX and PowerShell journeys in runner administration.

## Non-goals

- Installing Docker, Xcode, SDKs, compilers, or accepting license agreements.
- Granting deployment authority during ordinary runner enrollment.
- Automatically changing Linux group membership, system linger policy, or Windows service privileges.
- Hiding the public installer behind authentication or embedding an enrollment token in it.

## Users and use cases

### Primary user

A self-hosting administrator enrolling a trusted macOS, Linux, or Windows machine as outbound CI capacity.

### Use cases

1. Paste one POSIX command on macOS or Linux and receive the matching verified binary.
2. Enroll once with a short-lived token and install an idempotent launchd or systemd user service.
3. Paste the PowerShell command on Windows and receive the matching verified executable and explicit start guidance.
4. Re-run installation to upgrade the binary without silently reusing a config for another server.

## Requirements

### Functional requirements

- **FR-1:** `/install/rbe.sh` MUST support Darwin and Linux on normalized `arm64` and `amd64` architectures and reject every other target before download.
- **FR-2:** `/install/rbe.ps1` MUST support Windows `ARM64` and `AMD64` and reject every other target before download.
- **FR-3:** Installers MUST select the distinct release payload for the detected OS, extract only the expected versioned path, verify the GitHub asset digest, verify the downloaded binary's reported version, and replace the destination atomically.
- **FR-4:** The public installers MUST contain no enrollment token. Administration MAY inject a single-use token only into the copyable enrollment command through `ROBINE_RUNNER_ENROLLMENT_TOKEN`.
- **FR-5:** `rbe install` MUST retain and validate an explicit absolute config path and expected server before changing a service.
- **FR-6:** Darwin MUST reconcile a user LaunchAgent. Linux MUST reconcile a systemd user unit with `systemctl --user`; neither path may invoke or recommend `sudo`.
- **FR-7:** Service definitions MUST contain only the binary, `start`, the explicit config path, working directory, bounded PATH, restart policy, and log destinations. Credentials MUST remain only in the mode-`0600` config.
- **FR-8:** Reinstallation MUST stop only an identical manually started runner, preserve different runner processes, replace an already loaded identical service idempotently, and verify one managed PID with the requested binary and config.
- **FR-9:** Windows installation MUST remain explicit about the absence of Windows service reconciliation until that capability is implemented; it MUST NOT claim foreground execution is durable.

### UX requirements

- **UX-1:** Administration → Runners MUST use the generic title “Install rbe” and distinguish POSIX and Windows commands without describing every runner as a Mac.
- **UX-2:** Failure output MUST distinguish unsupported platform, missing prerequisite, release metadata, digest, archive, config, service-manager, process, and connection failures without secrets.
- **UX-3:** Linux output MUST explain that Docker executor use requires the runner account to access Docker and that durable operation may require operator-managed user lingering.

### Operational requirements

- **OR-1:** All downloads MUST require HTTPS and TLS 1.2 or newer where the platform API permits it.
- **OR-2:** Temporary files and configuration/service directories MUST be private and cleaned after success, failure, or interruption.
- **OR-3:** Shell and PowerShell scripts MUST be syntax-checked in CI; service reconciliation MUST have deterministic unit tests.
- **OR-4:** Installation MUST require no language runtime or package manager beyond operating-system-provided download, archive, hashing, and service tools.

## Proposed design

The POSIX installer maps `uname -s` and `uname -m` to the release payload and Go target names, then follows the existing metadata, digest, extraction, version, and atomic replacement path. `rbe install` dispatches to launchd on Darwin and a systemd user unit on Linux. Both share config identity validation, connection probing, duplicate-process handling, private logs, and post-start connection verification.

PowerShell performs the same release and digest checks using native cmdlets and `tar.exe`. It installs `rbe.exe` atomically and prints exact enrollment/start guidance. Windows service management remains a separately testable follow-up rather than an implicit scheduled task.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Unsupported OS or architecture | Installer exits before download | Use a released supported target |
| Digest or version mismatch | Destination remains unchanged | Investigate the release and retry |
| Config belongs to another server | Service remains unchanged | Enroll a new config or pass the intended path |
| systemd user manager unavailable | Unit is retained with bounded diagnostics but not reported running | Enable the user manager/linger according to host policy and rerun |
| Runner cannot connect | Managed process failure is classified without exposing credentials | Correct DNS, network, TLS, upstream, or authentication state |

## Security and privacy

The installation surface is public and token-free. Enrollment credentials exist only in one process environment and the private runner config. Service definitions, process arguments, download URLs, diagnostics, and repository content never contain credentials. Installer extraction is restricted to one exact release path and refuses links or unexpected file types.

## Observability

Installation reports the selected version, OS, architecture, destination, non-secret config identity, managed PID, and protocol connection result. Service logs remain private to the runner account. Fleet administration exposes the resulting capabilities through protocol v1.

## Acceptance criteria

- [x] One POSIX script installs verified Darwin and Linux `arm64`/`amd64` binaries.
- [x] Linux systemd installation is idempotent and verifies one connected PID without credentials in unit or logs.
- [ ] PowerShell installs verified Windows `ARM64`/`AMD64` binaries and gives honest foreground guidance.
- [x] Administration exposes generic POSIX and Windows commands and a one-use enrollment journey.
- [x] Automated tests cover platform mapping, digest/version enforcement, service replacement, config mismatch, duplicate processes, diagnostics, and secret exclusion.

## Open questions

None blocking. Windows service management is explicitly deferred.

## Out of scope / future work

- A native Windows Service or Scheduled Task implementation.
- Automatic Docker installation or privilege/group changes.
- Package-manager repositories, Homebrew taps, apt repositories, and winget manifests.
