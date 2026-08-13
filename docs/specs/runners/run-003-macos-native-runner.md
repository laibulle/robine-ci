# RUN-003 — macOS native runner

## Status

- **State:** Shipped
- **Owner:** Execution
- **Target:** Post-MVP
- **Last updated:** 2026-08-13

## Summary

Robine provides a dedicated macOS runner that executes trusted CI commands directly on a Mac, allowing projects to build and test Apple-platform software with the same outbound runner protocol and scheduling model as existing Docker runners.

## Problem

Docker runners provide Linux environments even when Docker Desktop runs on macOS. Projects that require Xcode, Apple SDKs, signing tools, the Darwin kernel, or Apple Silicon therefore cannot validate their real target platform.

## Goals

- Enroll and operate a Mac through the existing outbound-only runner protocol.
- Schedule a job explicitly onto normalized `macos` and `arm64` or `amd64` capabilities.
- Run sequential shell steps in a fresh attempt workspace on the host.
- Preserve cancellation, timeout, log redaction, source transfer, and terminal-result semantics.

## Non-goals

- Running untrusted repositories or forks.
- Virtual-machine isolation, macOS containers, or automatic Mac provisioning.
- Service containers and code signing in the first increment.
- Installing Xcode or accepting Apple license agreements automatically.

## Users and use cases

### Primary user

A self-hosted operator with a dedicated Mac who needs CI evidence from macOS or Apple Silicon.

### Use cases

1. Build the runner artifact on the target Mac and enroll it with a single-use token.
2. Start the runner as a dedicated, unprivileged launchd service.
3. Run a trusted workflow job declaring `runs-on: [macos]` or `runs-on: [macos, arm64]`.
4. Cancel a running job and remove its attempt workspace.

## Requirements

### Functional requirements

- **FR-1:** A runner on Darwin MUST report `os=macos`, a normalized `arm64` or `amd64` architecture, `native=true`, and `docker=false` for its native executor.
- **FR-2:** The scheduler MUST consider a connected native runner executable capacity without making it eligible for the default `docker` requirement.
- **FR-3:** Every attempt MUST use a fresh private temporary workspace removed after success, failure, cancellation, timeout, or runner error.
- **FR-4:** Source files MUST be copied without following or retaining symbolic links, devices, sockets, or other special entries.
- **FR-5:** Run steps MUST execute sequentially with the declared shell, shared attempt workspace, environment, and in-memory secrets.
- **FR-6:** Non-zero commands, timeouts, cancellation, conditional steps, and terminal results MUST preserve the shared execution contract.
- **FR-7:** Output MUST be bounded and secrets MUST be redacted across arbitrary output chunk boundaries before protocol delivery or result retention.
- **FR-8:** Native jobs containing service containers MUST fail preparation explicitly until that capability is implemented.
- **FR-9:** Cache and artifact built-ins MUST use the same authenticated attempt-scoped transfer callbacks, bounded safe archives, and workspace path policy as Docker jobs.

### UX requirements

- **UX-1:** Fleet administration MUST display `macos`, architecture, native execution mode, connectivity, and capacity separately from administrator labels.
- **UX-2:** Installation documentation MUST include a launchd configuration, filesystem permissions, prerequisites, enrollment, upgrade, and removal commands.

### Operational requirements

- **OR-1:** Production use MUST dedicate a non-administrator local account and machine to trusted CI workloads.
- **OR-2:** The runner MUST make only outbound TLS connections to the Robine control plane.
- **OR-3:** Operators MUST install target-native Erlang/OTP and Elixir versions because native Exile runtime files are not portable across OS or architecture.

## Proposed design

The existing standalone runner detects Darwin at startup and selects `NativeRunner`; Linux remains on `DockerRunner`. The protocol advertises normalized system capabilities, while `runs-on` continues to use the all-labels-match rule. Since jobs without `runs-on` require `docker`, they never land on the native Mac accidentally.

The native adapter creates an attempt-namespaced directory under the operating-system temporary directory, validates and copies the source tree, and launches each command through Exile with an explicit working directory and environment. It streams bounded output through the existing stateful secret redactor, polls durable cancellation, terminates the process on cancellation or timeout, and removes the workspace in an `after` block.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| No matching Mac is online | Job remains queued with unmet `macos` capacity | Start, enable, or relabel a Mac runner |
| Shell or tool is missing | Attempt fails without weakening execution semantics | Install the tool for the runner account or update the workflow |
| Runner process exits | Lease reconciliation reports runner loss | launchd restarts it; retry the job |
| Service container requested | Preparation fails with an explicit unsupported-capability reason | Split the workflow or use a Docker runner until support ships |

## Security and privacy

Native execution is not a sandbox. A job has the privileges of the runner account and can inspect that account's files and processes. Only trusted repositories may target it. The account MUST have no interactive administrator access, unrelated credentials, personal keychain data, or access to the Robine database. Secrets remain attempt-scoped and are redacted before log delivery.

## Observability

The existing runner connection, heartbeat, attempt, log, cancellation, and runner-loss signals apply. Fleet capabilities identify native macOS capacity explicitly.

## Acceptance criteria

- [x] Darwin and Apple Silicon facts normalize to `macos` and `arm64`, and select native execution.
- [x] Native capacity can be scheduled without satisfying the default `docker` label.
- [x] Sequential steps share a fresh workspace and output is redacted across chunk boundaries.
- [x] Command failure, conditional skip, cancellation, and cleanup are covered by automated tests.
- [x] Cache and artifact archives publish and restore through the shared transfer contract.
- [x] A target Mac builds the runner artifact, connects through TLS, and completes a real `runs-on: [macos]` pipeline.
- [x] launchd installation, upgrade, troubleshooting, and removal are documented and verified on macOS.

## Open questions

None blocking for the first increment.

## Out of scope / future work

- Service-container coordination for native jobs.
- Ephemeral macOS virtual machines and provider autoscaling.
- Keychain-backed signing identities and protected signing policy.
