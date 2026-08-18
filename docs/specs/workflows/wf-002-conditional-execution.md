# WF-002 — Conditional execution

## Status

- **State:** Shipped
- **Owner:** Workflows
- **Target:** Post-MVP
- **Last updated:** 2026-08-09

## Summary

Jobs and steps can use three fixed outcome conditions—`success`, `failure`, and `always`—to express cleanup, diagnostics, and failure-reporting flows without introducing a general-purpose expression language or provider-specific event syntax.

## Problem

Robine currently stops a job at its first failed step and skips every dependent job after a failed dependency. Teams therefore cannot publish diagnostics, tear down test state, or run a dedicated failure reporter inside the workflow. A free-form expression language would solve more cases but would add parsing, coercion, security, compatibility, and debugging complexity disproportionate to the immediate need.

## Goals

- Run cleanup and diagnostic steps after an ordinary step failure.
- Run dependent diagnostic jobs after one or more dependencies fail.
- Keep conditions deterministic, provider-neutral, source-located, and locally reproducible.
- Preserve immediate cancellation and timeout behavior.

## Non-goals

- Arbitrary expressions, functions, operators, interpolation, or dynamic values.
- Branch, tag, changed-path, actor, secret, environment, matrix, or provider-payload predicates.
- Continuing work after cancellation, timeout, runner loss, or control-plane revocation.
- Treating a cleanup success as recovery from the original failure.

## Users and use cases

### Primary user

A developer who needs reliable test cleanup and useful failure diagnostics from the same reproducible workflow in CI and through the local CLI.

### Use cases

1. Upload diagnostic artifacts only when an earlier command fails.
2. Run a cleanup step whether earlier commands succeed or fail.
3. Run a reporting job when any declared dependency fails.
4. Run a final aggregation job after every dependency reaches an ordinary terminal outcome.

## Requirements

### Functional requirements

- **FR-1:** A job or step MAY declare `if` with exactly one scalar value: `success`, `failure`, or `always`; absence MUST normalize to `success`.
- **FR-2:** A `success` job MUST queue only when every dependency succeeded. A `failure` job MUST queue after every dependency is terminal and at least one failed. An `always` job MUST queue after every dependency is terminal regardless of success, failure, or skip.
- **FR-3:** A `failure` job MUST declare at least one dependency. Independent jobs with `success` or `always` MUST queue normally.
- **FR-4:** A `success` step MUST run only while no prior step failed. A `failure` step MUST run only after a prior step failed. An `always` step MUST run after success or ordinary failure.
- **FR-5:** Conditions that do not match MUST produce a durable `skipped` job or step result; they MUST NOT be represented as success.
- **FR-6:** An ordinary failed step MUST remain the job's terminal failure even if later `failure` or `always` steps succeed. Later failures MUST be retained diagnostically without replacing the first failure reason.
- **FR-7:** Cancellation, timeout, runner loss, service loss, and system failure MUST stop further steps regardless of `if`.
- **FR-8:** A skipped dependency MUST count as terminal but not failed. Therefore it satisfies `always`, does not satisfy `failure` by itself, and prevents `success`.
- **FR-9:** Artifact access rules MUST remain unchanged: a conditional consumer may download only from a direct declared dependency and only an artifact already published by that attempt.
- **FR-10:** Server execution, remote runners, and `robine run` MUST evaluate the same normalized condition contract.

### UX requirements

- **UX-1:** Invalid condition values MUST produce stable source-located diagnostics at the exact `if` key.
- **UX-2:** Job and step views MUST display `skipped` distinctly and explain which fixed condition did not match.
- **UX-3:** Local output MUST show skipped steps and preserve the original failing command and exit code.
- **UX-4:** Documentation MUST recommend `always` for cleanup and `failure` for diagnostics, and explicitly state that neither runs after cancellation or timeout.

### Operational requirements

- **OR-1:** Condition evaluation MUST be pure, bounded, and require no network, filesystem, source-provider, secret, or wall-clock access.
- **OR-2:** Scheduler transactions MUST evaluate job conditions from the same locked durable dependency snapshot used for release.
- **OR-3:** Duplicate delivery and reconciliation MUST produce the same skipped/queued state without creating an attempt for a skipped job.
- **OR-4:** Adding conditions MUST NOT increase the workflow graph-depth, job-count, or step-count limits.

## Proposed design

The workflow domain adds `condition` to normalized jobs and steps as one of `success`, `failure`, or `always`. Persistence stores the normalized string in immutable job execution metadata. The pure pipeline release policy evaluates it once all dependencies are terminal and the SQLx adapter transitions the job atomically to `queued` or `skipped`; no attempt is created for a skipped job.

The execution contract carries each step condition. The Docker adapter no longer reduces steps by halting on an ordinary command/built-in failure. It retains the first failure, appends explicit skipped `StepResult` values for non-matching steps, and executes matching failure/always steps. Cancellation, timeout, service loss, and adapter errors still halt immediately. The final `Result` remains failed when any ordinary step failed.

This fixed enum is deliberate. Event and changed-path filtering belong in a later structured trigger specification; embedding GitHub payload fields or an expression interpreter here would weaken local equivalence and the future source-provider boundary.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Unknown condition | Workflow is invalid before pipeline creation | Select `success`, `failure`, or `always` |
| Failure job has no dependencies | Validation identifies the job condition | Add `needs` or use a normal job |
| Diagnostic artifact was never published | Conditional download fails with the existing precise artifact reason | Publish earlier or guard the diagnostic design |
| Cleanup step fails | Job remains failed and both failures are visible | Correct cleanup; original failure remains primary |
| Job is cancelled during cleanup | Remaining steps are not run | Retry if cleanup must be attempted again |

## Security and privacy

Conditions cannot read secrets, environment values, repository files, provider payloads, or arbitrary variables. They add no evaluator, code execution surface, dynamic property access, or string interpolation. Existing authorization, secret redaction, artifact scoping, and trusted-repository assumptions remain unchanged.

## Observability

Record normalized condition and outcome (`matched` or `skipped`) for job/step transitions using bounded enum labels. Metrics include skipped jobs and steps by condition and terminal pipeline outcome. Logs and telemetry never include the values of environment variables or secrets as condition inputs because such inputs do not exist.

## Acceptance criteria

- [x] Invalid job and step conditions produce identical source-located CLI/server diagnostics.
- [x] Success, failure, and always jobs transition deterministically from the same dependency snapshot under concurrent reconciliation.
- [x] Failure and always steps run after an ordinary command failure while success steps skip, locally and on a remote runner.
- [x] Cancellation, timeout, and service loss prevent every remaining step including always.
- [x] Skipped jobs create no attempt and render distinctly in pipeline, job, and GitHub projections.
- [x] The first ordinary failure remains primary when later diagnostic or cleanup steps fail.
- [x] Architecture and full QA checks remain green.

## Open questions

None blocking. The fixed three-value condition contract is intentionally not extensible through arbitrary strings or `x-` keys.

## Out of scope / future work

- Structured event/branch/path predicates, manual inputs, matrices, boolean composition, reusable predicates, and a general expression language.
