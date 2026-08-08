# EXEC-001 — Local Docker runner

## Status

- **State:** Draft
- **Owner:** Execution
- **Target:** MVP
- **Last updated:** 2026-08-08

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

### Operational requirements

- **OR-1:** Global and per-repository concurrency limits MUST be configurable.
- **OR-2:** Image pulls and log streams MUST have bounded time and memory behavior.
- **OR-3:** The runner MUST refuse unsupported privileged configuration instead of silently weakening isolation.
- **OR-4:** Disk pressure MUST prevent new dispatch before it destabilizes active work, using configurable thresholds.

## Proposed design

The runner lifecycle is `accepted → preparing → running → cancelling → cleaning → terminal`. It creates a labeled workspace volume, pulls or locates the image, starts a long-lived container with a minimal command, then executes each step through Docker exec. Built-ins execute through runner-owned implementations against the workspace.

The local CLI calls the same execution library and constructs the same normalized execution specification. Differences, such as CI-provided metadata and secrets, are explicit inputs rather than hidden branches.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Image pull fails | Attempt fails as infrastructure/image error | Fix image or registry access and retry |
| Docker daemon disappears | Attempt is marked runner-lost after reconciliation | Restore Docker and retry |
| Command exceeds timeout | Process and container are terminated | Increase timeout or optimize command |
| Cleanup partially fails | Result is retained with cleanup warning | Background reconciler retries cleanup |
| Host disk is low | No new job is accepted | Free disk or adjust storage policy |

## Security and privacy

Only trusted repository code is supported. The Docker socket is controlled by the runner and MUST NOT be mounted into job containers. Host paths MUST NOT be mountable by workflow authors. Registry credentials and job secrets are redacted and scoped to the shortest practical lifetime.

## Observability

Metrics include active and queued attempts, phase duration, image pull duration, bytes logged, cancellation latency, cleanup failures, orphan count, disk-pressure state, and exit-reason classes.

## Acceptance criteria

- [ ] Files created by one step are available to later steps in the same job.
- [ ] Writable files from one job are unavailable to another job unless explicitly transferred.
- [ ] Cancellation and timeouts terminate the full container process tree within the configured grace period.
- [ ] Restart reconciliation removes or adopts every labeled orphan deterministically.
- [ ] The configured concurrency limit is respected under simultaneous dispatch.
- [ ] Job containers cannot access the Docker socket through Robine-provided mounts.

## Open questions

- Define supported CPU and memory limit configuration for the MVP.
- Select the default cancellation grace period and disk-pressure thresholds.
- Decide the supported behavior for images without a usable non-root user or shell.

## Out of scope / future work

- Remote runners, micro-VM isolation, service containers, GPU/device access, and autoscaling.

