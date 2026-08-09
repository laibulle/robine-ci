# WF-005 — Scheduled workflows

## Status

- **State:** Shipped
- **Owner:** Workflows
- **Target:** Post-MVP
- **Last updated:** 2026-08-09

## Summary

Trusted repositories can declare bounded UTC cron schedules that Robine evaluates durably. A due occurrence resolves the repository's current default-branch head, validates the workflow at that exact SHA, and creates one idempotent pipeline whose intended schedule time is retained and visible.

## Problem

Maintenance, dependency checks, nightly suites, and periodic validation should run without a synthetic commit or a proprietary provider scheduler. A process-local timer alone is insufficient because restarts, overlapping nodes, retries, and temporary GitHub failures must not silently lose or duplicate occurrences.

## Goals

- Declare portable schedules in workflow YAML without GitHub Actions dispatch APIs.
- Create exactly one pipeline per repository, workflow, cron expression, and due minute.
- Recover a bounded period of missed minutes after downtime or dependency failure.
- Preserve the intended UTC occurrence, exact execution SHA, and system actor.

## Non-goals

- Per-workflow time zones, daylight-saving-time semantics, seconds, calendars, holidays, or provider dispatch APIs.
- User-supplied scheduled inputs, secret prompts, branch selection, or schedule-specific job mutation.
- Reconstructing the historical default-branch SHA that existed during an offline occurrence.

## Users and use cases

### Primary user

A repository maintainer declaring periodic trusted CI work and an operator diagnosing scheduler health.

### Use cases

1. Run a nightly integration workflow at `02:00` UTC.
2. Run a weekday maintenance workflow every 30 minutes.
3. Restart Robine after a short outage and recover every bounded missed occurrence once.
4. See the intended occurrence and exact fetched SHA on the resulting pipeline.

## Requirements

### Functional requirements

- **FR-1:** Workflow v1 MAY declare `on.schedule` as a list of one to eight maps containing only `cron`.
- **FR-2:** `cron` MUST be a unique UTF-8 string of at most 100 bytes with exactly five fields: minute, hour, day of month, month, and day of week.
- **FR-3:** Fields MUST support `*`, numeric values, comma lists, inclusive ranges, and positive steps. Bounds are minute `0..59`, hour `0..23`, day `1..31`, month `1..12`, and weekday `0..7`, with `0` and `7` both Sunday. Names and macros are invalid.
- **FR-4:** Matching MUST use UTC minute precision. When day-of-month and day-of-week are both restricted, either field matching MUST satisfy the day predicate, matching conventional cron semantics.
- **FR-5:** Every due occurrence MUST resolve the trusted repository's current default-branch head and fetch workflow content only at the returned lowercase 40-character SHA.
- **FR-6:** A created pipeline MUST persist trigger `schedule`, actor `system:scheduler`, intended `scheduled_for`, exact SHA, workflow revision, jobs, and ordinary outbox event atomically.
- **FR-7:** The idempotency identity MUST include repository ID, exact workflow path, cron expression, and intended UTC minute. Reconciliation retries and concurrent nodes MUST return the same pipeline.
- **FR-8:** The scheduler MUST use a durable compare-and-set cursor, retry a failed scan without advancing it, and process at most 1,440 due minutes per reconciliation. The first scan starts at its current UTC minute.
- **FR-9:** After downtime beyond 24 hours, Robine MUST process the newest 1,440 minutes, expose the truncated backlog, and advance only after the bounded scan succeeds.
- **FR-10:** Scheduled workflows MUST compose with matrices, conditions, services, secrets, caches, artifacts, local runners, and remote runners without changing their semantics.

### UX requirements

- **UX-1:** The repository page MUST show schedules discovered from an explicitly displayed exact default-branch SHA.
- **UX-2:** Pipeline detail MUST identify the schedule trigger and intended UTC occurrence separately from creation and start times.
- **UX-3:** GitHub checks MUST identify a scheduled trigger without invoking a provider scheduling API.
- **UX-4:** Invalid schedule syntax MUST use stable source-located diagnostics shared by CLI and server validation.

### Operational requirements

- **OR-1:** Cron parsing and matching MUST be pure, deterministic, bounded, and independent of Oban or wall-clock APIs.
- **OR-2:** One reconciliation MUST fetch each trusted repository head and workflow set at most once, regardless of the number of recovered minutes.
- **OR-3:** A repository/GitHub/validation/pipeline failure MUST fail the scan and retain its prior cursor for idempotent retry.
- **OR-4:** Metrics MUST expose scan duration, outcome, scanned minutes, due occurrences, created-or-reused pipelines, and truncated minutes using bounded labels only.

## Proposed design

```yaml
on:
  schedule:
    - cron: "0 2 * * *"
    - cron: "*/30 9-17 * * 1-5"
```

The workflow domain owns a `CronExpression` value object and a `Schedule` definition. Validation normalizes cron syntax without framework dependencies. The repository context owns a `ReconcileScheduledWorkflows` use case because it coordinates trusted repositories, exact-SHA GitHub reads, workflow validation, the Pipelines facade, and a repository-owned durable cursor port.

The Oban adapter invokes the facade once per minute. The use case computes the bounded minute interval after the stored cursor, fetches each trusted repository once, evaluates every normalized schedule against every minute, and calls `Pipelines.create_pipeline/2` with a deterministic idempotency key. It advances the cursor with compare-and-set only after the complete scan succeeds.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Duplicate or overlapping reconciliation | Same occurrence returns one pipeline | Idempotency and cursor CAS converge automatically |
| GitHub unavailable | No cursor advancement | Oban retries, then the next scan catches up |
| Workflow becomes invalid | No occurrence from the failing scan is forgotten | Correct workflow; reconciliation retries |
| Downtime under 24 hours | Every missed minute is evaluated | Automatic bounded catch-up |
| Downtime over 24 hours | Oldest excess minutes are reported as truncated | Operator reviews health; newest 24 hours run |
| Default head moved during downtime | Catch-up uses the exact head resolved during recovery | Pipeline displays both intended time and execution SHA |

## Security and privacy

Only trusted repositories are scanned. Schedules cannot inject values or select refs. Scheduled pipelines use the existing secret policy and system actor, and audit metadata contains repository, path, cron, occurrence, SHA, pipeline, and outcome without secrets.

## Observability

Emit bounded reconciliation duration/outcome plus scanned, due, pipeline, and truncated counts. Health reports cursor age and the last sanitized failure. Audit every created or reused occurrence without workflow source, input values, repository names, or credentials.

## Acceptance criteria

- [x] Valid and invalid cron fixtures produce identical source-located CLI/server contracts.
- [x] Pure matching covers wildcards, lists, ranges, steps, Sunday normalization, and day-field OR semantics.
- [x] A due workflow creates one exact-SHA scheduled pipeline with its intended minute and ordinary jobs/outbox.
- [x] Duplicate/concurrent scans create no duplicate pipeline and advance one durable cursor.
- [x] GitHub or validation failure retains the cursor; bounded recovery later creates each missed occurrence once.
- [x] Repository, pipeline, GitHub check, metrics, audit, architecture, release smoke, and full QA remain green (326 tests).

## Open questions

None blocking. UTC-only behavior and a 24-hour recovery bound are deliberate first-contract constraints.

## Out of scope / future work

- Named time zones, longer backfill policies, schedule pause controls, parameters, calendars, and historical-ref reconstruction.
