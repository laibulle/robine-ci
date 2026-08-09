# WF-001 — Workflow format

## Status

- **State:** Shipped
- **Owner:** Workflows
- **Target:** MVP
- **Last updated:** 2026-08-08

## Summary

Robine workflows are versioned YAML documents under `.robine-ci/workflows/`. They define event filters and a directed acyclic graph of Docker jobs while deliberately avoiding compatibility claims with GitHub Actions.

## Problem

Developers need a readable, locally validatable CI definition with predictable execution semantics. Copying the full GitHub Actions language would import proprietary behavior, accumulated complexity, and an unsustainable compatibility promise.

## Goals

- Make simple pipelines concise and complex dependencies explicit.
- Produce source-located validation errors.
- Keep the format evolvable through an explicit schema version.
- Use the identical parser and semantic validator in the server and CLI.

## Non-goals

- Running GitHub Actions or supporting `uses` marketplace references.
- Templating, arbitrary expressions, dynamic job generation, or matrices in the MVP. Bounded static post-MVP matrices are specified separately by WF-003.
- Deployment environments and manual approval gates.

## Users and use cases

### Primary user

A developer writing build and test automation in a trusted repository.

### Use cases

1. Run tests on pushes and pull requests.
2. Run independent jobs in parallel.
3. Make one job depend on successful output from another.
4. Cache dependencies and transfer declared artifacts.

## Requirements

### Functional requirements

- **FR-1:** Workflow files MUST end in `.yml` or `.yaml` and exist directly below `.robine-ci/workflows/`.
- **FR-2:** Every document MUST include `version`, `name`, `on`, and `jobs`.
- **FR-3:** `version` MUST equal `1` for the MVP.
- **FR-4:** Job identifiers MUST match `^[a-z][a-z0-9_-]{0,62}$` and be unique within the workflow.
- **FR-5:** Docker image tags and digest references are accepted in the MVP. Tags MUST produce a reproducibility warning; digest references are RECOMMENDED for stable CI.
- **FR-6:** Every job MUST contain at least one step, and every step MUST contain exactly one of `run` or a supported built-in `uses` value.
- **FR-7:** The MVP built-ins MUST be `checkout`, `cache/restore`, `cache/save`, `artifacts/upload`, and `artifacts/download`.
- **FR-8:** `needs` MUST reference existing jobs and MUST form a directed acyclic graph.
- **FR-9:** Jobs without unmet dependencies SHOULD run concurrently within the runner concurrency limit.
- **FR-10:** A dependent job MUST run only when all needed jobs succeed, unless a future condition feature explicitly changes this behavior.
- **FR-11:** Step names MUST be unique within a job after generated defaults are applied.
- **FR-12:** Unknown keys MUST be validation errors, except keys prefixed with `x-`, which MUST be ignored and preserved by format-aware tools.
- **FR-13:** Environment values MUST be strings; YAML implicit booleans and numbers MUST be normalized only when unambiguous and otherwise rejected with guidance.
- **FR-14:** Workflow configuration MUST come from the exact commit being built.

### UX requirements

- **UX-1:** Validation errors MUST include file, line, column when available, a stable error code, and a corrective suggestion.
- **UX-2:** The UI and CLI MUST display the expanded job graph before execution on request.
- **UX-3:** Warnings such as mutable image tags MUST not prevent local execution but MUST remain visible.

### Operational requirements

- **OR-1:** Parsing and validation MUST not execute user code or resolve arbitrary network resources.
- **OR-2:** Workflow size, job count, step count, and dependency depth MUST have configurable limits with documented defaults.

The defaults are 256 KiB of YAML, 64 jobs, 128 steps per job, 512 total steps, and dependency depth 16. Operators MAY lower or raise them with `ROBINE_WORKFLOW_MAX_BYTES`, `ROBINE_WORKFLOW_MAX_JOBS`, `ROBINE_WORKFLOW_MAX_STEPS_PER_JOB`, `ROBINE_WORKFLOW_MAX_TOTAL_STEPS`, and `ROBINE_WORKFLOW_MAX_GRAPH_DEPTH`. All limit failures use stable `workflow.limit_*` diagnostics before pipeline creation.

## Proposed design

```yaml
version: 1
name: CI

on:
  push:
    branches: [main]
  pull_request: {}

jobs:
  test:
    image: hexpm/elixir:1.18.4-erlang-27.3
    timeout: 20m
    env:
      MIX_ENV: test
    steps:
      - name: Checkout
        uses: checkout
      - name: Restore dependencies
        uses: cache/restore
        with:
          key: mix-${{ checksum('mix.lock') }}
          paths: [deps, _build]
      - name: Install dependencies
        run: mix deps.get
      - name: Test
        run: mix test
```

The checksum expression shown above is the only MVP interpolation and is restricted to cache keys. It accepts exactly `checksum('relative/path')`, hashes one regular file from the exact checked-out revision with SHA-256, and substitutes the lowercase hexadecimal digest. Missing files, traversal, symlinks, directories, and every other expression are validation or preparation errors. General expression evaluation is not part of the MVP.

Built-in inputs are fixed as follows:

- `checkout` accepts no inputs.
- `cache/restore` and `cache/save` require `key` and `paths` (one to 32 safe workspace-relative paths).
- `artifacts/upload` requires `name` and `paths` and accepts `retention-days` from 1 through 90, defaulting to seven.
- `artifacts/download` requires `name` and `from` (a dependency job ID) and accepts a safe relative `path`, defaulting to the workspace root.
- Unknown inputs are errors except preserved `x-` extensions.

Jobs share one container and workspace across their sequential steps. Each `run` step executes using `/bin/sh -e` by default; a job MAY declare another shell executable present in its image. Every step receives the exit status of its command, and the first failed step stops the job.

Post-MVP workflow v1 also accepts the bounded `services` job map defined by [EXEC-002](../execution/exec-002-service-containers.md). A service has an exact DNS identifier, image, optional user/environment/secret-environment/command, and optional TCP readiness check. It never publishes a host port or receives the job workspace.

Post-MVP workflow v1 accepts bounded static `strategy.matrix` expansion as defined by [WF-003](wf-003-job-matrices.md). This adds only fixed image tokens and declared `ROBINE_MATRIX_*` environment values; it does not add a general expression evaluator.

Version 1 accepts only `/bin/sh` and `/bin/bash` as explicit `shell` values. `/bin/sh` is the default. If the selected executable is absent, preparation fails with `shell_unavailable` before any user step runs.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| YAML syntax error | Workflow is invalid and does not run | Correct the source-located error |
| Dependency cycle | All cycle members are identified | Remove at least one dependency |
| Unsupported schema version | File remains unexecuted | Upgrade Robine or use a supported version |
| Missing built-in input | Validation identifies the step and key | Add the required input |

## Security and privacy

Configuration from the built commit is executable repository code and is trusted under SEC-001. Secret values MUST use a dedicated reference syntax and MUST never be permitted in cache keys, job names, or other persisted display fields.

## Observability

Validation outcomes record workflow revision, schema version, error codes, warning codes, and validation duration without recording secret values.

Every semantic diagnostic is enriched from a parser-owned path-to-source index after domain validation. The public diagnostic contains stable path, one-based line, and one-based column without exposing yamerl records. The versioned valid/invalid compatibility corpus lives under `test/fixtures/workflows` and is exercised identically through the server facade and CLI JSON renderer.

## Acceptance criteria

- [x] The same fixture corpus produces identical validation results in the CLI and server.
- [x] Cycles, missing dependencies, duplicate names, unknown keys, and invalid built-ins are rejected before dispatch.
- [x] Independent jobs execute concurrently and dependent jobs wait for successful prerequisites.
- [x] A workflow taken from a pull request commit is the workflow that executes.
- [x] Every invalid fixture reports a stable error code and source location where the parser permits it.

## Open questions

- None.

## Out of scope / future work

- Reusable workflows, deployment environments, approvals, and marketplace actions.
