# QUAL-001 — Coverage reporting

## Status

- **State:** Shipped
- **Owner:** Robine maintainers
- **Target:** Post-MVP
- **Last updated:** 2026-08-18

## Summary

Robine measures its Rust workspace coverage with a 75% quality gate and publishes the same durable result through CI provider checks.

## Problem

Contributors cannot currently measure coverage with one documented command, enforce a shared minimum, or inspect missed lines before coverage is exposed in CI.

## Goals

- Provide one deterministic local command that measures the complete Rust workspace and writes an LCOV report.
- Fail the command when total coverage is below 75%.
- Retain the HTML report and summarize the measured result in Robine CI provider checks.

## Non-goals

- Require a third-party hosted coverage service.
- Publish coverage to source-control providers in the initial local-only increment.
- Enforce per-file thresholds or coverage changes relative to another branch.

## Users and use cases

### Primary user

A Robine contributor validating a change before pushing it to CI.

### Use cases

1. Run `cargo llvm-cov --workspace --all-features --lcov --output-path coverage.lcov` from a local checkout and receive a blocking pass/fail result.
2. Inspect the same measured result and retained LCOV report after a CI run.

## Requirements

### Functional requirements

- **FR-1:** The repository MUST run `cargo llvm-cov` for the complete workspace in CI.
- **FR-2:** The command MUST run the complete Rust test suite and generate `coverage.lcov` under ignored local output.
- **FR-3:** Total coverage below 75% MUST fail the command.
- **FR-4:** Coverage publication MUST consume the same measurement contract in CI.
- **FR-5:** A completed coverage run MUST emit one bounded marker containing the total, threshold, and retained report name.
- **FR-6:** Robine MUST add a valid retained marker to the pipeline and job provider-check summaries without exposing provider credentials to the job.
- **FR-7:** Provider-check summaries MUST link to an authenticated retained report download.
- **FR-8:** Every trusted repository MUST expose a stable public SVG badge containing only its latest retained percentage.
- **FR-9:** Every trusted repository MUST expose a stable public SVG build badge reflecting its newest pipeline, including active states.

### UX requirements

- **UX-1:** Contributor documentation MUST state the command, threshold, and report path.
- **UX-2:** The terminal MUST show total and per-file coverage.
- **UX-3:** Provider checks MUST show the measured percentage, threshold, gate outcome, and retained report name.
- **UX-4:** The README badge URL MUST remain stable across pipelines and commits.

### Operational requirements

- **OR-1:** Generated reports MUST remain outside version control.
- **OR-2:** Local and CI coverage MUST NOT require a provider token or hosted coverage account inside the job.
- **OR-3:** Check projection MUST ignore absent or malformed markers and MUST bound log pagination.

## Proposed design

`cargo-llvm-cov` instruments the workspace and writes `coverage.lcov`. CI extracts the total, enforces the 75% threshold, and keeps generated coverage output outside version control. Database compatibility tests use `ROBINE_DATABASE_INTEGRATION_URL`; the Rust persistence suite bootstraps a fresh schema and exercises existing-schema compatibility.

The self-hosted workflow runs rustfmt, Clippy, tests, and dependency audit before coverage. It emits `ROBINE_COVERAGE total=<percentage> threshold=75 report=coverage-report`, then uploads `coverage.lcov` as a 14-day artifact. The repositories context parses only this bounded marker from retained job logs and enriches provider-neutral summaries with an authenticated artifact link. A public SVG badge resolves a trusted repository and exposes only its latest retained percentage. Provider credentials remain in the control plane.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Coverage is below 75% | The command exits non-zero after printing the report | Add meaningful tests and rerun |
| A test fails | Coverage is still summarized, but the command exits non-zero | Fix the failing test or implementation |
| Test database is absent | Fresh-schema bootstrap creates it for compatibility tests | Correct PostgreSQL connectivity if setup fails |
| Marker is absent or malformed | The provider check retains its ordinary status summary | Inspect the coverage step and rerun |
| Checks permission is revoked | Local coverage and artifacts remain valid; projection retries | Restore `Checks: write` and approve the installation update |

## Security and privacy

Coverage executes ordinary tests and requires no new job secret. The report contains source paths and code excerpts, stays ignored locally, and is retained only for the trusted repository under the ordinary artifact authorization policy. Provider credentials remain in the control plane.

## Observability

The local command prints per-file and total percentages. CI retains the logs and report artifact, while provider checks expose the bounded total, threshold, outcome, and artifact name.

## Acceptance criteria

- [x] `cargo llvm-cov` measures the workspace and generates `coverage.lcov`.
- [x] The configured threshold is exactly 75% and is enforced with a non-zero exit below it.
- [x] The report directory is ignored and the command is documented.
- [x] A real Robine CI run retains the report and publishes its summary to the provider check.
- [x] Checks link to the retained archive and the repository exposes a stable coverage badge URL.
- [x] The repository exposes a stable build-status badge URL.

## Open questions

- None for the local increment.

## Out of scope / future work

- Coverage deltas against the default branch.
- Per-file gates and source annotations.
- Hosted coverage integrations.
