# RUN-002 — Runner fleet and scheduling

## Status

- **State:** Shipped
- **Owner:** Core team
- **Target:** Post-MVP
- **Last updated:** 2026-08-09

## Summary

Robine exposes an understandable fleet of local and remote runners and schedules each job only onto a compatible, available runner. Operators can label, drain, rotate, and revoke machines while provider-neutral autoscaling remains an adapter boundary rather than control-plane policy coupled to one cloud.

## Problem

Once multiple runners exist, simple first-available dispatch can send jobs to incompatible machines, starve repositories, or execute work on a machine under maintenance. Operators need trustworthy capacity and lifecycle controls without recreating a large cluster orchestrator.

## Goals

- Make job placement deterministic from declared requirements and reported capabilities.
- Distinguish operator-controlled labels from runner-reported facts.
- Let administrators drain, disable, rotate, and revoke runners without database access.
- Prevent one repository from monopolizing all compatible capacity under sustained load.
- Define an autoscaling port that can be implemented without changing scheduling use cases.

## Non-goals

- General-purpose container orchestration.
- Automatic bin packing by CPU or memory consumption in the first fleet release.
- A built-in AWS, GCP, Azure, Kubernetes, or bare-metal provisioner.
- Cross-instance marketplace runners.
- Scheduling untrusted workloads on shared trusted machines.

## Users and use cases

### Primary user

A Robine administrator operating a small heterogeneous fleet for a team or startup.

### Use cases

1. An administrator labels a runner for a workload such as `linux`, `x86_64`, `docker`, or `gpu`.
2. A workflow requests a set of runner labels and waits until compatible capacity exists.
3. An administrator drains a machine before maintenance without killing its current job.
4. A capacity adapter observes queued demand and creates or retires runners within configured bounds.
5. A developer sees why a job is waiting instead of an opaque queued state.

## Requirements

### Functional requirements

- **FR-1:** A workflow job MAY declare `runs-on` as a non-empty YAML sequence of normalized labels. Absence MUST mean the default requirement `docker`.
- **FR-2:** Label names and values MUST be lowercase ASCII, bounded to 63 characters, and limited to letters, digits, `.`, `_`, and `-`.
- **FR-3:** System capabilities such as operating system, architecture, Docker availability, runner version, and concurrency MUST be reported by the runner and displayed separately from administrator labels.
- **FR-4:** A runner MUST satisfy every requested label. Operator labels MUST NOT override contradictory system capabilities.
- **FR-5:** Runners MUST have one administrative state: `enabled`, `draining`, or `revoked`, and one derived connectivity state: `online`, `busy`, `offline`, or `stale`.
- **FR-6:** Draining MUST prevent new assignments while allowing active attempts to finish. Revocation MUST prevent authentication and request cancellation of active attempts.
- **FR-7:** Job selection and runner capacity reservation MUST be one atomic operation so concurrent schedulers cannot exceed runner concurrency.
- **FR-8:** The scheduler MUST use oldest-eligible-first ordering with bounded repository fairness among jobs of equal priority.
- **FR-9:** The scheduler MUST NOT assign a job whose repository trust policy is incompatible with the runner's isolation policy.
- **FR-10:** A queued job MUST expose unmet labels and whether compatible runners are offline, busy, draining, or absent.
- **FR-11:** Administrators MUST be able to list, inspect, rename, label, drain, enable, rotate credentials for, and revoke runners.
- **FR-12:** Fleet mutations MUST be audited with actor, target runner, before/after state, and timestamp.
- **FR-13:** An autoscaling policy MUST define a runner template, matching labels, minimum, maximum, idle timeout, scale-up cooldown, and scale-down cooldown.
- **FR-14:** Autoscaling use cases MUST depend on a provider port supporting provision, describe, and terminate operations with idempotency keys.
- **FR-15:** No autoscaling provider MUST be enabled by default. Static local and remote runners are the first supported fleet mode.

### UX requirements

- **UX-1:** The fleet page MUST show state, labels, capabilities, active capacity, version, last heartbeat, and recent failures without requiring log access.
- **UX-2:** Drain and revoke actions MUST explain their effect on active jobs and require confirmation when work is running.
- **UX-3:** The job page MUST explain placement delay in plain language and link administrators to matching fleet capacity.
- **UX-4:** Workflow validation MUST point to the exact `runs-on` label that is malformed or unsupported.

### Operational requirements

- **OR-1:** Scheduling a queued job against 1,000 registered runners SHOULD complete within 100 ms at the 95th percentile, excluding database lock contention.
- **OR-2:** Capability and heartbeat updates MUST be coalesced or bounded so a large idle fleet does not create unbounded database write load.
- **OR-3:** Autoscaler reconciliation MUST be idempotent and safe after process or control-plane restart.
- **OR-4:** Scale-down MUST select only idle, draining runners and MUST never terminate a machine with an active lease.
- **OR-5:** Runner version skew and incompatible protocol versions MUST be visible as degraded fleet health.

## Proposed design

Runner identity and connection follow RUN-001. The `Robine.Runners` domain owns labels, capabilities, lifecycle state, capacity reservations, and matching. Scheduling use cases receive runner-registry and job-queue ports; PostgreSQL adapters use transactional row or advisory locks for atomic selection and reservation. Phoenix LiveView is an administrative adapter, never a source of fleet policy.

`runs-on` uses an all-labels-match rule deliberately. Boolean expressions, weights, and cloud-specific selectors would create a second query language before evidence justifies it. The local Docker runner registers the system label `docker`, preserving existing workflow behavior.

Autoscaling is split into desired-capacity calculation and provider effects. The core produces idempotent provision/terminate intents; adapters implement a particular infrastructure API and report observed machines. This keeps open-source self-hosting useful without making any cloud provider privileged.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| No runner matches labels | Job remains queued with unmet requirements visible | Add/relabel a runner or change the workflow |
| All matching runners are busy | Job remains queued with capacity explanation | Wait for capacity or scale up |
| Runner goes stale during reservation | Lease is not renewed and no further job is assigned | Reconciler releases capacity and applies attempt retry policy |
| Concurrent schedulers select one slot | Exactly one reservation commits | Losing transactions retry selection |
| Provision request times out | Intent remains pending with the same idempotency key | Autoscaler reconciles provider state before retrying |
| Scale-down adapter fails | Runner stays drained and visible | Retry termination or re-enable manually |
| Administrator drains active runner | Current attempts continue; new work stops | Runner becomes idle, then can be maintained or terminated |

## Security and privacy

Only administrators may mutate fleet state or autoscaling policies. Runner-reported capabilities are untrusted assertions and cannot grant administrative labels or weaken isolation policy. Provider credentials remain inside provider adapters and are resolved through the existing secrets boundary. Audit events must not retain runner credentials, provider credentials, job secrets, or full environment payloads.

## Observability

Expose queue depth by normalized requirement set, eligible/busy/idle capacity, scheduling latency, fairness delay, reservation conflicts, stale runners, drain duration, version distribution, desired versus observed autoscaling capacity, and provider reconciliation errors. Correlate decisions with job, repository, runner, reservation, and autoscaling intent IDs.

## Acceptance criteria

- [x] Jobs run only on runners satisfying every declared label and trust constraint.
- [x] Existing workflows without `runs-on` continue on Docker-capable runners.
- [x] Two concurrent schedulers cannot reserve the same final runner slot.
- [x] Draining a busy runner lets its active job finish and prevents another assignment.
- [x] Revocation blocks reconnect and starts cancellation of active attempts.
- [x] A queued job visibly distinguishes absent, offline, draining, and busy matching capacity.
- [x] Sustained jobs from one repository do not indefinitely starve another repository with compatible work.
- [x] A fake autoscaling adapter proves restart-safe, idempotent scale-up and scale-down reconciliation.
- [x] Fleet administration is keyboard accessible and every destructive action is audited.

## Open questions

- None blocking. Scheduling weights and provider-specific adapters require separate accepted specifications.

## Out of scope / future work

- Boolean label expressions, runner groups, and organization quotas.
- Resource-aware bin packing and per-job CPU or memory reservations.
- Spot/preemptible capacity policy.
- Cloud-provider and Kubernetes adapters.
