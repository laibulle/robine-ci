# QUAL-001 — Coverage reporting

## Status

- **State:** Shipped
- **Owner:** Robine maintainers
- **Target:** Post-MVP
- **Last updated:** 2026-08-09

## Summary

Robine measures its own Elixir test coverage locally with a 75% quality gate and publishes the same durable result through CI provider checks.

## Problem

Contributors cannot currently measure coverage with one documented command, enforce a shared minimum, or inspect missed lines before coverage is exposed in CI.

## Goals

- Provide one deterministic local command that prepares the test database and generates an HTML report.
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

1. Run `mix coverage` from a local checkout, receive a blocking pass/fail result, and open the generated HTML report.
2. Inspect the same measured result and retained HTML report after a CI run.

## Requirements

### Functional requirements

- **FR-1:** The repository MUST expose `mix coverage` in the test environment.
- **FR-2:** The command MUST prepare the test database, run the complete test suite, and generate an HTML report under ignored local output.
- **FR-3:** Total coverage below 75% MUST fail the command.
- **FR-4:** Coverage publication MUST consume the same measurement contract in CI.
- **FR-5:** A completed coverage run MUST emit one bounded marker containing the total, threshold, and retained report name.
- **FR-6:** Robine MUST add a valid retained marker to the pipeline and job provider-check summaries without exposing provider credentials to the job.
- **FR-7:** Provider-check summaries MUST link to an authenticated retained report download.
- **FR-8:** Every trusted repository MUST expose a stable public SVG badge containing only its latest retained percentage.

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

ExCoveralls runs as a test-only dependency through the `coverage` Mix alias. `coveralls.json` owns the 75% global threshold, treats modules with no relevant executable lines as covered, and limits the metric to application code by excluding test-support fixtures and release-oriented Mix tasks. The alias creates and migrates the test database before invoking the complete suite with `coveralls.html --raise`. The generated `cover/excoveralls.html` report remains ignored locally.

The self-hosted workflow runs formatting and warning checks before the same coverage alias. It emits `ROBINE_COVERAGE total=<percentage> threshold=75 report=coverage-report`, then uploads `cover/` as a 14-day artifact even after an ordinary coverage failure. The repositories context parses only this bounded marker from at most 50 pages of retained job logs and enriches provider-neutral pipeline and job summaries with an authenticated artifact download link. A public, cacheable SVG badge resolves a trusted repository by provider and owner/name and exposes only the latest retained percentage. GitHub publication uses the existing GitHub App installation token in the control plane and its `Checks: write` permission; no token enters the execution container.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Coverage is below 75% | The command exits non-zero after printing the report | Add meaningful tests and rerun |
| A test fails | Coverage is still summarized, but the command exits non-zero | Fix the failing test or implementation |
| Test database is absent | The alias creates and migrates it | Correct PostgreSQL connectivity if setup fails |
| Marker is absent or malformed | The provider check retains its ordinary status summary | Inspect the coverage step and rerun |
| Checks permission is revoked | Local coverage and artifacts remain valid; projection retries | Restore `Checks: write` and approve the installation update |

## Security and privacy

Coverage executes ordinary tests and requires no new job secret. The report contains source paths and code excerpts, stays ignored locally, and is retained only for the trusted repository under the ordinary artifact authorization policy. Provider credentials remain in the control plane.

## Observability

The local command prints per-file and total percentages. CI retains the logs and report artifact, while provider checks expose the bounded total, threshold, outcome, and artifact name.

## Acceptance criteria

- [x] `mix coverage` prepares the database and generates `cover/excoveralls.html`.
- [x] The configured threshold is exactly 75% and is enforced with a non-zero exit below it.
- [x] The report directory is ignored and the command is documented.
- [x] A real Robine CI run retains the report and publishes its summary to the provider check.
- [x] Checks link to the retained archive and the repository exposes a stable coverage badge URL.

## Open questions

- None for the local increment.

## Out of scope / future work

- Coverage deltas against the default branch.
- Per-file gates and source annotations.
- Hosted coverage integrations.
