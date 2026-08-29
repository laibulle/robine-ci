# RUN-004 — Bundled Go Docker runner

## Status

- **State:** Accepted
- **Owner:** Core team
- **Target:** Post-MVP
- **Last updated:** 2026-08-29

## Summary

Robine executes server-hosted CI capacity through the same self-contained Go runner and protocol used by remote machines. The Phoenix control plane no longer owns the Docker socket or executes repository commands in the BEAM.

## Problem

The server currently has a privileged in-process Elixir Docker execution path in addition to the remote Go runner. Two executors create semantic drift, couple control-plane availability to workload failures, expose the Docker socket to Phoenix, and make a nominally local attempt bypass the authenticated runner lifecycle.

## Goals

- Make the bundled Linux runner a separately supervised Go process using runner protocol v1.
- Preserve Docker jobs, service containers, secrets, caches, artifacts, conditions, cancellation, timeouts, limits, diagnostics, and cleanup semantics.
- Remove server-side job execution and Docker-socket access from Phoenix in production.
- Keep a safe, reversible migration gate until Go/Docker parity is verified.

## Non-goals

- Granting deployment authority to the bundled CI runner.
- Treating Docker as an isolation boundary for hostile repositories.
- Replacing the developer-facing `robine run` command in this feature.
- Running macOS or Windows containers.

## Users and use cases

### Primary user

A self-hosting operator who installs one Robine server and expects it to provide trusted Linux Docker capacity without manually enrolling another machine.

### Use cases

1. Install or upgrade Robine and receive one automatically enrolled local Docker runner.
2. Execute ordinary and service-backed jobs without exposing Docker to the server container.
3. Restart either server or runner and recover through protocol reconciliation.
4. Disable bundled capacity and use only separately enrolled runners.

## Requirements

### Functional requirements

- **FR-1:** The bundled runner MUST be the released Linux `rbe` binary and MUST connect through protocol v1 as a persisted runner identity.
- **FR-2:** The Go runner MUST advertise `docker: true`, `native: false`, `executor: docker`, `deployments: false`, and bounded concurrency only after Docker readiness succeeds.
- **FR-3:** Docker execution MUST provide fresh attempt containers, workspaces, networks, service containers, readiness probes, resource ceilings, private `/tmp`, conditions, redacted ordered logs, timeouts, cancellation, built-ins, and idempotent cleanup.
- **FR-4:** The bundled identity MUST enroll automatically from a single-use token exchanged through a mode-`0600` shared bootstrap file. Tokens and credentials MUST NOT appear in process arguments, Compose configuration, logs, or Git.
- **FR-5:** The server scheduler MUST dispatch server-hosted work through the normal runner selection and offer path. Production MUST NOT fall back to the Elixir local executor when bundled mode is enabled.
- **FR-6:** Operators MUST be able to disable bundled capacity explicitly. Existing remote runners MUST continue to use the same scheduling contract.
- **FR-7:** The server release MUST contain the matching Linux `rbe` binary and Compose MUST run it as a separate service with the Docker socket mounted only into that service.
- **FR-8:** A revoked or missing bundled credential MUST require a new single-use bootstrap exchange; it MUST NOT silently create an unrestricted identity.

### UX requirements

- **UX-1:** Administration MUST show the bundled runner as an ordinary named runner with software version, capabilities, heartbeat, and active attempts.
- **UX-2:** Readiness MUST distinguish control-plane health from available bundled CI capacity.
- **UX-3:** Bootstrap, Docker, service, network, authentication, and protocol failures MUST have bounded secret-free diagnostics.

### Operational requirements

- **OR-1:** The Phoenix container MUST NOT mount `/var/run/docker.sock` in the production bundle.
- **OR-2:** The runner MUST label every owned Docker resource with attempt and instance namespaces and reconcile only matching labeled orphans.
- **OR-3:** Server and runner restarts MUST not duplicate attempt execution or lose the durable terminal outcome.
- **OR-4:** The Go runner MUST remain `CGO_ENABLED=0`, pass at least 75% aggregate coverage, and build for the release host architecture.
- **OR-5:** The bundled runner MUST run with no control-plane database, encryption, provider, object-store, bootstrap-administrator, or session secrets.

## Proposed design

The production bundle has four services: PostgreSQL, Phoenix, `runner`, and the HTTPS proxy. Phoenix owns durable scheduling, transfer authorization, and event persistence. The runner owns the Docker socket and all execution effects. It connects to the configured public HTTPS URL exactly like a remote runner.

Phoenix writes a generated single-use enrollment token atomically to a private shared runner state volume only when bundled mode is enabled and no runner config exists. The runner entrypoint reads the token into `ROBINE_RUNNER_ENROLLMENT_TOKEN`, enrolls to the configured public URL, deletes the token file, then starts `rbe`. Its config and credential remain mode `0600` in the runner-only state volume.

`rbe` selects its executor from explicit config. Darwin defaults to native; the bundled Linux config uses Docker. Docker effects use argument vectors through the installed Docker CLI. Repository commands run only inside the job container. The control plane retains the existing normalized execution document and attempt-scoped transfer endpoints.

The scheduler retains an explicit development/test fallback during migration, but production bundled mode treats missing compatible runner capacity as queued capacity rather than executing in Phoenix. After parity evidence, the production Compose bundle removes the Docker socket from `server` and the Elixir Docker adapter is no longer reachable from server dispatch.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Bootstrap file cannot be created | Server readiness is degraded with a bounded filesystem reason | Repair runner-state ownership and restart |
| Enrollment fails | Runner exits without retaining the one-use token in logs | Correct DNS/TLS/server availability; issue a fresh bootstrap token if consumed |
| Docker is unavailable | Runner does not advertise Docker capacity and queued jobs remain queued | Restore Docker and restart the runner |
| Runner disconnects during a job | Lease and reconnect reconciliation decide the durable outcome | Restore the runner or retry after lease recovery |
| Service readiness fails | Attempt fails before user commands with a redacted bounded diagnostic | Correct service configuration and retry |
| Cleanup is interrupted | Labeled resources remain eligible for runner reconciliation | Restore Docker; reconciliation removes only owned orphans |

## Security and privacy

The runner is a trusted host agent but is not a control-plane administrator. Its credential authorizes only runner protocol and attempt-scoped transfers. Only the runner service receives the Docker socket. Job and service configuration remains limited to trusted repositories and never receives the host socket. The bootstrap token is single-use and short-lived; the long-lived runner credential exists only in the private runner config volume.

## Observability

Expose bundled bootstrap state, runner connectivity, Docker readiness, active attempt count, reconciliation outcome, and classified execution failures. Correlate by runner and attempt identifiers without logging commands, URLs, repository names, environment values, tokens, or credentials.

## Acceptance criteria

- [x] A clean production install automatically enrolls one bundled Go runner and shows protocol-v1 Docker capacity.
- [x] A Docker job with PostgreSQL and Redis services, secrets, cache restore/save, and artifact upload/download succeeds through the Go runner.
- [x] Cancellation, timeout, runner restart, and server restart retain one terminal attempt and leave no owned Docker resources.
- [x] The Phoenix production service has no Docker socket while the runner has only its state, release binary, and Docker socket mounts.
- [x] With bundled mode enabled and the runner offline, a compatible job remains queued and never executes in the BEAM.
- [x] Revocation and rebootstrap create a new credential without exposing either secret.
- [x] Go tests and real Docker integration tests pass with aggregate coverage at or above 75%.

## Open questions

None blocking.

## Out of scope / future work

- Replacing the local developer CLI executor with direct use of `rbe`.
- Deployment-capable bundled identities, autoscaling, micro-VM isolation, and rootless Docker.
