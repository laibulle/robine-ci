# PLAT-001 — System architecture

## Status

- **State:** Shipped
- **Owner:** Platform
- **Target:** MVP
- **Last updated:** 2026-08-18

## Summary

Robine uses a Rust/Actix Web control plane backed by PostgreSQL and a logically separate runner interface. The default runner executes on the same Docker host, while outbound HTTPS runner sessions support remote execution without exposing an inbound runner port.

## Problem

The system must provide responsive real-time behavior and durable orchestration without coupling product semantics to a single-machine topology or treating in-memory process state as durable state.

## Goals

- Separate durable orchestration from ephemeral job execution.
- Preserve a simple single-host deployment for the MVP.
- Permit a future authenticated remote runner without redesigning workflow semantics.
- Make recovery deterministic after process, host, or network failures.

## Non-goals

- Multi-region control-plane clustering.
- A language-runtime distribution protocol between control plane and runners.
- Exactly-once execution; Robine provides at-least-once dispatch with attempt identity.
- A generic workflow engine independent of CI.

## Users and use cases

### Primary user

An operator deploying Robine on a Linux Docker host and a contributor implementing control-plane or runner behavior.

### Use cases

1. Accept an event and persist a pipeline graph.
2. Dispatch ready jobs to an eligible runner.
3. stream logs and state changes to the browser.
4. Recover or reconcile work after a restart.

## Requirements

### Functional requirements

- **FR-1:** PostgreSQL MUST be the source of truth for repositories, workflow revisions, pipelines, jobs, attempts, steps, secrets metadata, caches, and artifacts metadata.
- **FR-2:** Async runtime tasks MAY coordinate active work but MUST NOT be the sole owners of durable state.
- **FR-3:** Every execution dispatch MUST use a unique attempt ID and an idempotency token.
- **FR-4:** A job MUST have at most one active attempt according to durable control-plane state.
- **FR-5:** State transitions MUST be validated against an explicit state machine.
- **FR-6:** The runner boundary MUST use a versioned application protocol over authenticated HTTPS; it MUST NOT depend on language-runtime distribution.
- **FR-7:** Browser clients MUST receive authenticated SSE updates only after the corresponding durable transition commits.

### UX requirements

- **UX-1:** Users MUST see whether work is queued, executing, cancelling, cancelled, successful, failed, or blocked by infrastructure.
- **UX-2:** Infrastructure failures MUST not masquerade as user command failures.

### Operational requirements

- **OR-1:** Dispatch and reconciliation MUST be safe under duplicate messages.
- **OR-2:** Webhook ingestion, scheduling, execution, and GitHub delivery MUST use bounded retry policies.
- **OR-3:** The system MUST apply backpressure rather than spawning unbounded processes or Docker containers.
- **OR-4:** The maximum local concurrency MUST be configurable and default conservatively based on operator configuration, not automatic host probing alone.
- **OR-5:** A periodic durable reconciliation MUST redispatch eligible queued jobs so a lost, conflicted, or prematurely consumed dispatch notification cannot leave committed work queued indefinitely.

## Proposed design

Rust crates separate source control, workflows, pipelines, identity, secrets, storage, execution, persistence, and Actix delivery. Their dependency rules, application services, traits, and adapters are defined by [PLAT-002](plat-002-clean-application-architecture.md). SQL-backed durable jobs handle webhook processing, reconciliation, and provider projections. A scheduler claims ready jobs using transactional database locking and sends an execution specification to a local or remote runner. Reconciliation recovers committed queued work after lost or conflicted notifications.

Pipeline states are `created`, `queued`, `running`, `cancelling`, and terminal states `succeeded`, `failed`, `cancelled`, or `invalid`. Job attempts distinguish command failure, cancellation, timeout, runner loss, and system failure. Retrying creates a new attempt; it never mutates the history of the previous attempt.

Every pipeline transaction stores one immutable workflow revision containing the exact source path and bytes, a SHA-256 digest, and the normalized execution graph. Source-triggered pipelines provide the fetched workflow bytes from the exact commit SHA; synthetic internal pipelines receive an explicit generated revision rather than a missing reference.

The runner emits ordered, sequence-numbered events. The control plane deduplicates events and persists state before broadcasting it. This protocol is implemented locally in the MVP but MUST not rely on shared mutable process state, so it can be transported remotely later.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Actix process crashes | Committed state remains available | The service manager restarts it; reconcilers resume work |
| Duplicate dispatch | Runner recognizes the attempt token | Existing attempt is returned; no second container is created |
| Runner disappears | Attempt becomes `runner_lost` after lease expiry | Job may be retried explicitly or by policy |
| Event arrives twice | No duplicate transition or log segment | Sequence/idempotency key is ignored after first commit |

## Security and privacy

Runner execution specifications contain only secrets required by the job. Future runner credentials are scoped, rotatable, and revocable. Internal APIs authenticate every runner request and never rely only on network location.

## Observability

Telemetry MUST cover queue latency, dispatch latency, active jobs, state-transition failures, retry counts, runner leases, SSE delivery, and reconciliation outcomes. Correlation IDs connect webhook, pipeline, job, attempt, and outbound check events.

## Acceptance criteria

- [x] Killing and restarting the Actix application does not corrupt or forget accepted pipeline state.
- [x] Duplicate dispatch of the same attempt cannot create two active containers.
- [x] A configured concurrency limit is never exceeded.
- [x] A runner loss is visibly distinct from a failed build command.
- [x] No MVP interface requires Erlang distribution to be exposed.

## Open questions

None blocking. PostgreSQL owns durable work; attempts use bounded leases and heartbeats with periodic resource reconciliation. `robine-application` is the orchestration boundary and focused Rust tests enforce the PLAT-002 dependency rules.

## Out of scope / future work

- Remote runner enrollment, labels, capabilities, autoscaling, and multi-node control planes.
