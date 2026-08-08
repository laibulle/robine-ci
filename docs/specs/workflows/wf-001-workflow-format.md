# WF-001 — Workflow format

## Status

- **State:** Draft
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
- Templating, arbitrary expressions, dynamic job generation, or matrices in the MVP.
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
- **FR-5:** Every job MUST specify an immutable Docker image reference by digest in accepted production semantics; tags MAY be accepted with a reproducibility warning.
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

The checksum expression shown above is the only proposed MVP interpolation and is restricted to cache keys. General expression evaluation is not part of the MVP. Before acceptance, the schema MUST specify whether this expression remains or is replaced by an explicit checksum field.

Jobs share one container and workspace across their sequential steps. Each `run` step executes using `/bin/sh -e` by default; a job MAY declare another shell executable present in its image. Every step receives the exit status of its command, and the first failed step stops the job.

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

## Acceptance criteria

- [ ] The same fixture corpus produces identical validation results in the CLI and server.
- [ ] Cycles, missing dependencies, duplicate names, unknown keys, and invalid built-ins are rejected before dispatch.
- [ ] Independent jobs execute concurrently and dependent jobs wait for successful prerequisites.
- [ ] A workflow taken from a pull request commit is the workflow that executes.
- [ ] Every invalid fixture reports a stable error code and source location where the parser permits it.

## Open questions

- Finalize the cache-key checksum syntax without introducing a general expression language.
- Define default limits for file size, jobs, steps, and graph depth.
- Decide whether mutable image tags produce only a warning or can be forbidden by instance policy.

## Out of scope / future work

- Matrices, conditional expressions, reusable workflows, services, scheduled triggers, manual inputs, and marketplace actions.

