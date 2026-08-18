# WF-003 — Job matrices

## Status

- **State:** Shipped
- **Owner:** Workflows
- **Target:** Post-MVP
- **Last updated:** 2026-08-09

## Summary

A job may declare a bounded static matrix whose Cartesian product expands into independently scheduled jobs. Every variant uses the existing Docker execution contract, receives fixed matrix environment variables, and remains reproducible through `robine run` without adding a general expression language.

## Problem

Developers need to test the same repository against several language, runtime, database, or platform versions. Copying nearly identical jobs is noisy and makes dependencies, local reproduction, and result comparison harder. An unbounded dynamic strategy or general expression evaluator would undermine Robine's deterministic validation and scheduling model.

## Goals

- Express a small Cartesian test matrix once in YAML.
- Expand every variant deterministically before durable pipeline creation.
- Schedule, display, reproduce, and project each variant as an ordinary job.
- Keep graph, job, and step limits effective after expansion.

## Non-goals

- Dynamic matrices derived from files, commands, APIs, provider payloads, or earlier jobs.
- `include`, `exclude`, `fail-fast`, per-matrix concurrency, boolean expressions, or computed axes.
- Matrix interpolation in commands, secrets, paths, cache keys, artifact names, labels, or dependency identifiers.
- Pairwise dependency matching between matrices.
- Aggregating or downloading artifacts from a dependency with more than one variant.

## Users and use cases

### Primary user

A developer testing one codebase against a bounded set of supported runtime combinations.

### Use cases

1. Test two Elixir versions against two OTP versions.
2. Run one downstream aggregation job only after every expanded test variant succeeds.
3. Reproduce all variants or one generated variant through the local CLI.
4. Compare each variant independently in the Actix browser and GitHub checks.

## Requirements

### Functional requirements

- **FR-1:** A job MAY declare `strategy.matrix` as a map of one to four axes; absence MUST produce one ordinary job.
- **FR-2:** Axis identifiers MUST match `^[a-z][a-z0-9_]{0,30}$`. Each axis MUST contain one to eight unique string values matching `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`.
- **FR-3:** A matrix MUST expand to at most 32 variants. The expanded workflow MUST still satisfy the configured total job and total step limits.
- **FR-4:** Expansion order MUST sort axis identifiers lexicographically and preserve each axis value's declaration order.
- **FR-5:** A generated job key MUST be `<base>[axis=value,...]` using the deterministic axis order. The base key remains the YAML dependency and CLI group identifier.
- **FR-6:** Every variant MUST receive `ROBINE_MATRIX_<UPPER_AXIS>` environment variables. A matrix job MUST be invalid if its explicit environment collides with one of those names.
- **FR-7:** The exact token `${{ matrix.<axis> }}` MAY appear in a job or service Docker image and MUST be replaced before persistence. No other matrix interpolation is accepted.
- **FR-8:** A dependency on a matrix job MUST fan in over every generated variant. A matrix consumer also fans in over every dependency variant; pairwise matching is not inferred.
- **FR-9:** Existing `success`, `failure`, and `always` job conditions MUST evaluate after every expanded dependency is terminal.
- **FR-10:** Each expanded variant MUST be an ordinary durable job with its own attempts, logs, services, cache and artifact operations, runner matching, retry state, and GitHub check.
- **FR-11:** An `artifacts/download` step MUST be invalid when its declared source expands to more than one variant. Uploads remain scoped to the expanded producer job.
- **FR-12:** `robine run <base>` MUST execute the selected matrix group and its dependencies. `robine run '<generated-key>'` MUST select exactly that variant and its dependencies.
- **FR-13:** Matrix values, generated keys, and expanded environment MUST be immutable workflow-revision data and MUST never be evaluated at runner time.

### UX requirements

- **UX-1:** Invalid strategy shape, axes, values, interpolation, collisions, and post-expansion limits MUST produce stable source-located diagnostics.
- **UX-2:** Validation and graph views MUST show the number and exact generated keys of all variants.
- **UX-3:** Pipeline, job, CLI, and GitHub surfaces MUST display generated keys consistently and expose the bounded axis/value map.
- **UX-4:** Local output MUST identify each variant before execution and retain the overall non-zero result if any selected variant fails.

### Operational requirements

- **OR-1:** Matrix expansion MUST be pure, bounded, deterministic, and require no filesystem, network, clock, secret, provider, or runner access.
- **OR-2:** Expansion MUST complete during validation before any pipeline, job, attempt, outbox event, or provider check is persisted.
- **OR-3:** The existing default limits of 64 jobs, 128 steps per job, 512 total steps, and graph depth 16 apply to the expanded graph.
- **OR-4:** Matrix metrics MUST use only bounded outcome and count labels; axis names and values MUST NOT become metric labels.

## Proposed design

```yaml
jobs:
  test:
    strategy:
      matrix:
        elixir: ["1.18.4", "1.19.0"]
        otp: ["27.3", "28.0"]
    image: hexpm/elixir:${{ matrix.elixir }}-erlang-${{ matrix.otp }}
    steps:
      - run: mix test

  summarize:
    image: alpine:3.22
    needs: test
    if: always
    steps:
      - run: echo "all test variants are terminal"
```

Validation normalizes the base job and a pure matrix value object, expands the Cartesian product, substitutes image tokens, injects `ROBINE_MATRIX_ELIXIR` and `ROBINE_MATRIX_OTP`, and rewrites base dependencies to generated keys. The returned validated workflow contains only expanded jobs plus each job's `base_id` and immutable `matrix_values`; pipeline creation therefore needs no separate matrix scheduler.

The generated keys for the example are `test[elixir=1.18.4,otp=27.3]`, `test[elixir=1.18.4,otp=28.0]`, `test[elixir=1.19.0,otp=27.3]`, and `test[elixir=1.19.0,otp=28.0]`. `summarize` needs all four.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Product exceeds 32 variants | Source-located validation failure before persistence | Reduce axes or values |
| Expanded graph exceeds operator limits | Existing expanded job/step limit diagnostic | Split the workflow or adjust a deliberate operator limit |
| Unknown image axis token | Validation identifies the image | Declare the axis or correct the token |
| Matrix environment collision | Validation identifies the explicit environment key | Rename the explicit variable |
| Downstream artifact download is ambiguous | Validation identifies `with.from` | Use one producer or defer aggregation to a later feature |
| One variant fails | Other variants remain independent; downstream conditions use all outcomes | Retry that generated job or reproduce it locally |

## Security and privacy

Axes and values are repository-authored non-secret identifiers persisted in workflow revisions, job keys, logs, URLs, and provider checks. They cannot read secrets, files, provider payloads, or environment values. Generated environment variables contain only declared matrix values. The fixed image substitution does not evaluate functions, properties, operators, or arbitrary strings.

## Observability

Validation records the expanded job count and matrix variant count as measurements. Expansion failures use stable diagnostic codes. Scheduling, attempts, logs, and checks retain their existing telemetry; axis names and values are never metric labels.

## Acceptance criteria

- [x] A two-axis matrix expands in deterministic order with exact keys, image substitutions, environment, and fan-in dependencies.
- [x] Invalid axes, values, products, tokens, collisions, ambiguous artifacts, and post-expansion limits are rejected at source locations.
- [x] Expanded variants schedule independently and conditional downstream jobs release from their durable outcomes.
- [x] CLI execution by base group and exact generated key matches CI contracts and terminal results.
- [x] Pipeline/job LiveViews and GitHub checks distinguish every variant and expose its values.
- [x] Duplicate delivery, retry, remote runners, service images, architecture checks, and full QA remain green.

## Open questions

None blocking. The first contract deliberately favors a small predictable Cartesian product over compatibility with another CI strategy language.

## Out of scope / future work

- Include/exclude rows, fail-fast, max-parallel, pairwise dependencies, artifact aggregation, dynamic matrices, structured command substitution, and reusable workflow parameters.
