# PLAT-001 — System architecture

## Status

- **State:** Draft
- **Owner:** Platform
- **Target:** MVP
- **Last updated:** 2026-08-09

## Summary

Robine uses an Elixir/Phoenix control plane backed by PostgreSQL and a logically separate runner interface. The MVP runner executes on the same Docker host, while the protocol and ownership boundaries allow remote runners to be added later without exposing Erlang distribution.

## Problem

The system must provide responsive real-time behavior and durable orchestration today without coupling product semantics to a single-machine topology or treating an in-memory OTP process as durable state.

## Goals

- Separate durable orchestration from ephemeral job execution.
- Preserve a simple single-host deployment for the MVP.
- Permit a future authenticated remote runner without redesigning workflow semantics.
- Make recovery deterministic after process, host, or network failures.

## Non-goals

- Multi-region control-plane clustering.
- Direct Erlang distribution between untrusted networks.
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
- **FR-2:** OTP processes MAY coordinate active work but MUST NOT be the sole owners of durable state.
- **FR-3:** Every execution dispatch MUST use a unique attempt ID and an idempotency token.
- **FR-4:** A job MUST have at most one active attempt according to durable control-plane state.
- **FR-5:** State transitions MUST be validated against an explicit state machine.
- **FR-6:** The runner boundary MUST use a versioned application protocol; future remote runners MUST communicate over authenticated HTTPS and WebSocket connections, not Erlang distribution.
- **FR-7:** LiveView clients MUST receive updates through Phoenix PubSub after the corresponding durable transition commits.

### UX requirements

- **UX-1:** Users MUST see whether work is queued, executing, cancelling, cancelled, successful, failed, or blocked by infrastructure.
- **UX-2:** Infrastructure failures MUST not masquerade as user command failures.

### Operational requirements

- **OR-1:** Dispatch and reconciliation MUST be safe under duplicate messages.
- **OR-2:** Webhook ingestion, scheduling, execution, and GitHub delivery MUST use bounded retry policies.
- **OR-3:** The system MUST apply backpressure rather than spawning unbounded processes or Docker containers.
- **OR-4:** The maximum local concurrency MUST be configurable and default conservatively based on operator configuration, not automatic host probing alone.

## Proposed design

The Phoenix application contains bounded contexts for source control, workflows, pipelines, identity, secrets, and storage. Their internal dependency rules, use cases, ports, adapters, and public facades are defined by [PLAT-002](plat-002-clean-application-architecture.md). A durable background-job mechanism handles webhook processing, reconciliation, and outbound GitHub updates. A scheduler claims ready jobs using transactional database locking and sends an execution specification to a local runner adapter.

Pipeline states are `created`, `queued`, `running`, `cancelling`, and terminal states `succeeded`, `failed`, `cancelled`, or `invalid`. Job attempts distinguish command failure, cancellation, timeout, runner loss, and system failure. Retrying creates a new attempt; it never mutates the history of the previous attempt.

Every pipeline transaction stores one immutable workflow revision containing the exact source path and bytes, a SHA-256 digest, and the normalized execution graph. Source-triggered pipelines provide the fetched workflow bytes from the exact commit SHA; synthetic internal pipelines receive an explicit generated revision rather than a missing reference.

The runner emits ordered, sequence-numbered events. The control plane deduplicates events and persists state before broadcasting it. This protocol is implemented locally in the MVP but MUST not rely on shared mutable process state, so it can be transported remotely later.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Phoenix process crashes | Committed state remains available | Supervisors restart processes; reconciler resumes work |
| Duplicate dispatch | Runner recognizes the attempt token | Existing attempt is returned; no second container is created |
| Runner disappears | Attempt becomes `runner_lost` after lease expiry | Job may be retried explicitly or by policy |
| Event arrives twice | No duplicate transition or log segment | Sequence/idempotency key is ignored after first commit |

## Security and privacy

Runner execution specifications contain only secrets required by the job. Future runner credentials are scoped, rotatable, and revocable. Internal APIs authenticate every runner request and never rely only on network location.

## Observability

Telemetry MUST cover queue latency, dispatch latency, active jobs, state-transition failures, retry counts, runner leases, PubSub delivery, and reconciliation outcomes. Correlation IDs connect webhook, pipeline, job, attempt, and outbound check events.

## Acceptance criteria

- [x] Killing and restarting the Phoenix application does not corrupt or forget accepted pipeline state.
- [x] Duplicate dispatch of the same attempt cannot create two active containers.
- [x] A configured concurrency limit is never exceeded.
- [x] A runner loss is visibly distinct from a failed build command.
- [x] No MVP interface requires Erlang distribution to be exposed.

## Open questions

None blocking. Oban owns durable work; attempts use 60-second leases and 20-second heartbeats, with five-minute resource reconciliation. `Robine.Runtime.Dependencies` is the composition root and focused ExUnit checks enforce the PLAT-002 dependency rules.

## Out of scope / future work

- Remote runner enrollment, labels, capabilities, autoscaling, and multi-node control planes.
