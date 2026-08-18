# WF-004 — Manual workflow inputs

## Status

- **State:** Shipped
- **Owner:** Workflows
- **Target:** Post-MVP
- **Last updated:** 2026-08-09

## Summary

Trusted-repository maintainers can launch a declared workflow manually from any named branch with a small typed input form. Robine resolves the selected branch head to an immutable Git SHA, validates the workflow at that exact revision, persists the normalized non-secret inputs, and injects them into every job through reserved environment variables.

## Problem

Some CI work—release candidates, maintenance checks, migrations, and explicit rebuilds—must run on demand with a few operator-selected values. Requiring a synthetic Git push is awkward, while accepting arbitrary environment variables or mutable refs would weaken reproducibility, authorization, and secret boundaries.

## Goals

- Launch a workflow from a trusted repository without creating a Git event.
- Collect only inputs declared by the exact workflow revision.
- Preserve the exact SHA, actor, input values, and idempotent launch request.
- Reproduce the same normalized job environment locally with explicit CLI inputs.

## Non-goals

- Secret inputs, arbitrary environment variables, file uploads, rich JSON, multiline values, or provider expressions.
- Selecting an arbitrary tag or SHA; manual launches accept named branches only.
- Approvals, deployment environments, reusable-workflow parameters, or scheduled invocations.
- GitHub's proprietary `workflow_dispatch` API or compatibility with GitHub Actions inputs.

## Users and use cases

### Primary user

A repository maintainer launching an explicitly enabled maintenance or release workflow.

### Use cases

1. Choose `staging` or `production` from a bounded choice input.
2. Enter a release version string and opt into a boolean dry run.
3. See the exact commit and normalized values before and after launch.
4. Reproduce the workflow locally with the same declared values.

## Requirements

### Functional requirements

- **FR-1:** Workflow v1 MAY declare `on.workflow_dispatch.inputs` with zero to 16 input definitions; absence of `workflow_dispatch` MUST make manual launch unavailable.
- **FR-2:** Input identifiers MUST match `^[a-z][a-z0-9_]{0,30}$`. Definitions accept only `description`, `type`, `required`, `default`, and `options`.
- **FR-3:** `type` MUST be `string`, `choice`, or `boolean` and defaults to `string`. `required` MUST be boolean and defaults to `false`.
- **FR-4:** Descriptions MUST be strings of at most 256 bytes. String defaults and submitted values MUST be single-line UTF-8 strings of at most 1,024 bytes.
- **FR-5:** A choice input MUST declare two to 32 unique bounded string options and any default/submitted value MUST equal one option. Non-choice inputs MUST NOT declare options.
- **FR-6:** Boolean defaults and submitted values normalize to the strings `true` or `false`; no other coercion is accepted.
- **FR-7:** Every missing optional input MUST use its default or the empty string. Every missing required input without a default MUST reject launch before pipeline creation.
- **FR-8:** Every job receives `ROBINE_INPUT_<UPPER_ID>` with the normalized value. A workflow is invalid if an explicit job environment collides with a declared input variable.
- **FR-9:** Manual discovery and launch MUST resolve the selected named branch through the installed source-control App, fetch workflows at that exact 40-character SHA, and select one exact workflow path. The provider-resolved SHA, never browser state, is authoritative.
- **FR-10:** Launch MUST be allowed only for a trusted repository and an administrator or maintainer. Viewers and anonymous users MUST be forbidden even if they forge a direct HTTP mutation.
- **FR-11:** The pipeline MUST persist trigger `workflow_dispatch`, initiating actor, exact SHA, workflow revision, and normalized input map before dispatch.
- **FR-12:** A caller-supplied opaque request ID MUST make duplicate submission idempotent. Reusing it with another repository, workflow, SHA, or input map MUST return a conflict.
- **FR-13:** `robine run` MAY accept repeated `--input name=value` flags, MUST validate them against the same declaration, and MUST reject undeclared, duplicate, or missing required values.
- **FR-14:** Manual inputs MUST compose with matrices, conditions, services, secrets, caches, artifacts, local runners, and remote runners without changing their existing semantics.

### UX requirements

- **UX-1:** The repository page MUST accept a branch name, discover manually enabled workflows from its current head, and clearly display both the resolved branch and immutable SHA.
- **UX-2:** The launch form MUST render text, select, and boolean controls with descriptions, required state, defaults, accessible labels, and inline stable errors.
- **UX-3:** Submission MUST disable duplicate clicks, then navigate to the created or reused pipeline.
- **UX-4:** Pipeline and job views MUST display the non-secret normalized inputs and include an exact local reproduction command.
- **UX-5:** GitHub checks MUST identify the trigger as manual without attempting to create a GitHub Actions dispatch.

### Operational requirements

- **OR-1:** Input validation and environment injection MUST be pure, deterministic, and bounded.
- **OR-2:** GitHub discovery and launch fetches MUST use installation authentication, existing retry/telemetry policy, and exact-SHA content requests.
- **OR-3:** No pipeline or outbox row may be persisted when SHA resolution, workflow fetch, validation, authorization, or input normalization fails.
- **OR-4:** Metrics MUST record bounded discovery/launch outcomes and input counts, never input names or values.

## Proposed design

```yaml
on:
  workflow_dispatch:
    inputs:
      environment:
        description: Deployment target
        type: choice
        required: true
        options: [staging, production]
      version:
        description: Release version
        type: string
        required: true
      dry_run:
        description: Validate without publishing
        type: boolean
        default: true
```

The workflow domain normalizes each definition into a `ManualInput` value object. A pure input policy validates a submitted string map and returns the complete normalized map. Job preparation merges the reserved `ROBINE_INPUT_*` variables before matrix expansion, so every expanded variant receives the same values.

The repository context exposes discovery and launch use cases. Both resolve the requested branch head through a source-control port and fetch workflow files by exact SHA. Launch re-resolves the branch and revalidates rather than trusting stale form state, calls the workflow input policy, injects values into normalized jobs, and calls the Pipelines facade with a canonical idempotency key. The pipeline stores inputs as a first-class map; runners receive only the resulting ordinary environment.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Selected branch head changes after form load | Launch re-resolves and revalidates the new exact revision | Review the displayed pipeline SHA |
| Selected branch is missing or invalid | No workflow or pipeline is created | Correct the branch name and load again |
| Workflow no longer enables manual launch | No pipeline is created | Restore `workflow_dispatch` or refresh discovery |
| Required/choice/boolean value invalid | Inline validation error; no persistence | Correct the field |
| GitHub installation unavailable | Degraded discovery/launch state | Restore credentials/connectivity and retry |
| Duplicate browser submission | Existing pipeline is returned | Continue to its pipeline page |
| Request ID reused with different data | Stable idempotency conflict | Generate a new launch request |

## Security and privacy

Inputs are explicitly non-secret and displayed in UI, logs, revisions, and audit metadata. The form warns users not to enter credentials. Secrets continue through SEC-001 only. Input names cannot override reserved or user-defined environment variables, and values never affect workflow structure, Docker arguments, cache keys, artifact identities, labels, or conditions.

## Observability

Record discovery and launch duration/outcome, workflow count, and input count with bounded labels. Audit actor, repository ID, workflow path, SHA, pipeline ID, and outcome; omit input values. GitHub API telemetry remains unchanged.

## Acceptance criteria

- [x] Valid string, choice, and boolean definitions produce identical source-located CLI/server contracts.
- [x] A maintainer launches from an exact default-branch SHA and every local/remote/matrix job receives the normalized environment.
- [x] Required, undeclared, duplicate, invalid choice/boolean, collision, stale workflow, untrusted repository, and forged viewer cases create no pipeline.
- [x] Duplicate request IDs return one pipeline and conflicting reuse is rejected.
- [x] Repository launch, pipeline detail, job detail, and CLI reproduction are accessible and preserve exact inputs.
- [x] GitHub checks, architecture rules, security scans, release smoke, and full QA remain green (313 tests).

## Open questions

None blocking. Branch selection and secret inputs are deliberately deferred.

## Out of scope / future work

- Tag/SHA selection, secret prompts, scheduled values, reusable-workflow inputs, approvals, structured objects, and provider dispatch APIs.
