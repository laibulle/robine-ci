# EXEC-001 — Local Docker runner

## Status

- **State:** Shipped
- **Owner:** Execution
- **Target:** MVP
- **Last updated:** 2026-08-10

## Summary

The local runner executes each job in one fresh Docker container, with sequential steps sharing a workspace. It enforces bounded concurrency, cancellation, timeouts, log streaming, and cleanup while making no claim that Docker safely contains hostile code.

## Problem

CI commands require an isolated and reproducible environment, but the MVP must remain operable on a single host. The executor needs precise lifecycle semantics so local and CI runs behave alike and interrupted work does not leak containers indefinitely.

## Goals

- Match local CLI and CI command semantics.
- Provide deterministic job, step, timeout, cancellation, and cleanup behavior.
- Keep the Docker host stable through bounded resource use.
- Preserve enough execution metadata to diagnose infrastructure failures.

## Non-goals

- Safe execution of malicious code.
- Privileged containers, Docker-in-Docker, host networking, or arbitrary device mounts.
- Windows or macOS containers.
- Remote execution in the MVP.

## Users and use cases

### Primary user

A developer running tests for a trusted repository and an operator sharing one Docker host across several trusted projects.

### Use cases

1. Create a fresh job container and checkout the requested commit.
2. Run sequential steps in the same workspace.
3. Stream ordered output and receive an accurate exit status.
4. Cancel or time out work and clean all resources.

## Requirements

### Functional requirements

- **FR-1:** Each job attempt MUST receive a new container, writable workspace volume, and unique resource labels.
- **FR-2:** Steps in a job MUST execute sequentially in that same container and working directory.
- **FR-3:** Different jobs MUST NOT share writable files except through explicit artifacts or caches.
- **FR-4:** The runner MUST capture stdout and stderr as ordered chunks with monotonic sequence numbers.
- **FR-5:** A non-zero command exit MUST fail the step and job unless future workflow semantics explicitly permit it.
- **FR-6:** Cancellation MUST first request graceful termination and MUST force termination after a bounded grace period.
- **FR-7:** Job timeout MUST include all container setup and step execution after dispatch acceptance, but not queue time.
- **FR-8:** The runner MUST remove containers and ephemeral volumes after terminal state, while preserving declared artifacts and logs according to retention policy.
- **FR-9:** The runner MUST reconcile and clean orphaned resources bearing its labels after restart.
- **FR-10:** Container execution MUST use a non-root user when the image supports it and MUST default to dropped Linux capabilities, no privileged mode, and no host network.
- **FR-11:** Secret environment values MUST be injected only for the duration of the attempt and MUST not be written into the execution specification stored with public job metadata.

### UX requirements

- **UX-1:** Image pull, container creation, checkout, command execution, cancellation, and cleanup MUST appear as distinct phases.
- **UX-2:** Failures MUST state whether they came from the command, image pull, Docker daemon, timeout, cancellation, or cleanup.
- **UX-3:** When the job container stops unexpectedly, the retained log MUST include its Docker status, exit code, OOM-killed flag, daemon error, and finish time captured before cleanup.

### Operational requirements

- **OR-1:** Global and per-repository concurrency limits MUST be configurable.
- **OR-2:** Image pulls and log streams MUST have bounded time and memory behavior.
- **OR-3:** The runner MUST refuse unsupported privileged configuration instead of silently weakening isolation.
- **OR-4:** Disk pressure MUST prevent new dispatch before it destabilizes active work, using configurable thresholds.

## Proposed design

The runner lifecycle is `accepted → preparing → running → cancelling → cleaning → terminal`. It creates a labeled workspace volume, pulls or locates the image, starts a long-lived container with a minimal command, then executes each step through Docker exec. Built-ins execute through runner-owned implementations against the workspace.

Before claiming a job, the control plane checks the storage filesystem and refuses admission below 2 GiB free or above 95% usage in production; both thresholds are configurable with `ROBINE_RUNNER_MIN_FREE_BYTES` and `ROBINE_RUNNER_MAX_USED_PERCENT`. Development defaults to 98% so self-hosted DinD can operate on smaller workstations, while tests isolate scheduling behavior from host disk occupancy. A queued-job view exposes disk admission separately from runner-label placement. Image inspection and any required pull are bounded and persisted as runner phase position `0`. Every container and volume carries the opaque `io.robine.attempt` label. A five-minute durable reconciliation compares those labels with active attempt IDs and removes only stale Robine-owned resources.

Every container defaults to 2 vCPU, 4 GiB of memory with swap disabled beyond that same limit, and 512 processes. Development raises the memory default to 16 GiB so Robine's self-hosted compilation and Docker-in-Docker test workload has sufficient headroom; production and test retain the 4 GiB default. Operators configure these ceilings with `ROBINE_RUNNER_CPU_MILLIS`, `ROBINE_RUNNER_MEMORY_BYTES`, and `ROBINE_RUNNER_PIDS_LIMIT`. Robine honors an image's configured `USER`. Images with no non-root user remain supported for trusted repositories, but still run with all capabilities dropped and `no-new-privileges`; the MVP does not claim this makes root images safe for hostile code.

The Docker client subprocess exposes stdout and stderr as separate demand-driven pipes. Robine reads whichever pipe becomes observable first, assigns one attempt-local monotonic sequence, applies an independent streaming redactor to each channel, and persists the channel on every bounded chunk. This ordering represents observation order; POSIX does not define a stronger total write order across two independent file descriptors. The terminal runner event uses the `system` channel and legacy batch results retain the explicit `combined` channel.

Cancellation is durable at pipeline level. Undispatched jobs become cancelled immediately and active jobs become cancelling. The runner polls the projection at most every 250 ms while a command is active, asks Docker to stop the full container, waits five seconds by default, and relies on Docker's forced kill after the grace period. Configure the grace with `ROBINE_RUNNER_CANCELLATION_GRACE_MS`.

The local CLI calls the same execution library and constructs the same normalized execution specification. The background worker no longer owns a private contract mapper: it calls the public `Execution.build_ci_specification/2` use case, while the CLI calls `build_local_plan/2`. Docker-backed success and failure fixtures compare every execution-semantic field and terminal result. Differences, such as attempt identity, CI-provided metadata, materialized source path, and secrets, are explicit inputs rather than hidden branches.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Image pull fails | Attempt fails as infrastructure/image error | Fix image or registry access and retry |
| Configured shell is absent | Preparation fails with `shell_unavailable`; no user step starts | Select `/bin/sh`, `/bin/bash`, or an image containing the configured shell |
| Docker daemon disappears | Attempt is marked runner-lost after reconciliation | Restore Docker and retry |
| Job container exits unexpectedly | Attempt fails as `system_failure`; its final Docker state is appended to the step log before cleanup | Use the exit code, OOM flag, and daemon error to adjust resources or repair the runner |
| Command exceeds timeout | Process and container are terminated | Increase timeout or optimize command |
| Cleanup partially fails | Result is retained with cleanup warning | Background reconciler retries cleanup |
| Host disk is low | No new job is accepted | Free disk or adjust storage policy |

## Security and privacy

Only trusted repository code is supported. The Docker socket is controlled by the runner and MUST NOT be mounted into job containers. Host paths MUST NOT be mountable by workflow authors. Registry credentials and job secrets are redacted and scoped to the shortest practical lifetime.

## Observability

Metrics include active and queued attempts, phase duration, image pull duration, bytes logged, cancellation latency, cleanup failures, orphan count, disk-pressure state, and exit-reason classes.

## Acceptance criteria

- [x] Files created by one step are available to later steps in the same job.
- [x] Writable files from one job are unavailable to another job unless explicitly transferred.
- [x] Cancellation and timeouts terminate the full container process tree within the configured grace period.
- [x] Restart reconciliation removes or adopts every labeled orphan deterministically.
- [x] The configured concurrency limit is respected under simultaneous dispatch.
- [x] Job containers cannot access the Docker socket through Robine-provided mounts.

## Open questions

None blocking.

## Decisions

- Job defaults are 2 vCPU, 4 GiB RAM with no additional swap, and 512 processes.
- Cancellation grace is five seconds. Admission requires 2 GiB free and at most 95% disk usage.
- The runner preserves the image-configured user. Root-only images are allowed for trusted repositories with reduced container privileges and an explicit security limitation.

## Out of scope / future work

- Micro-VM isolation, GPU/device access, and autoscaling. Attempt-scoped services are specified separately by EXEC-002.
