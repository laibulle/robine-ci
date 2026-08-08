# CLI-001 — Local developer experience

## Status

- **State:** Draft
- **Owner:** Developer Experience
- **Target:** MVP
- **Last updated:** 2026-08-08

## Summary

The `robine` CLI generates workflows, validates them with precise diagnostics, and reproduces CI jobs locally through the same normalized workflow and execution libraries used by the server.

## Problem

CI feedback loops are slow when configuration can only be tested after committing and pushing. Even after a failure, developers often cannot reproduce the hosted environment or determine the exact command and inputs that ran.

## Goals

- Validate workflow structure and semantics before pushing.
- Generate a useful starter workflow for common project types.
- Run a full workflow, one job, or one step locally.
- Explain unavoidable differences between local and CI execution.

## Non-goals

- Installing or managing Docker for the user.
- Perfect replication of GitHub events, network conditions, or architecture differences.
- A general-purpose package manager or remote-instance administration CLI.

## Users and use cases

### Primary user

A repository contributor with the Robine CLI and Docker Engine installed locally.

### Use cases

1. Run `robine init` to create a starter workflow.
2. Run `robine validate` in an editor or pre-commit hook.
3. Run `robine run`, `robine run <job>`, or a selected step.
4. Copy a reproduction command from a failed CI job.

## Requirements

### Functional requirements

- **FR-1:** `robine init` MUST inspect the repository without executing project code and propose, preview, then write a workflow only after confirmation unless `--yes` is passed.
- **FR-2:** `robine init` MUST NOT overwrite an existing workflow without explicit `--force` confirmation.
- **FR-3:** `robine validate` MUST use the same parser, schema, validator, and diagnostic codes as the server.
- **FR-4:** `robine validate --format json` MUST produce stable machine-readable diagnostics.
- **FR-5:** `robine run` MUST execute all jobs whose event-independent graph is runnable locally.
- **FR-6:** `robine run <job-id>` MUST execute the selected job and required dependencies by default; `--no-deps` MAY skip them with a warning.
- **FR-7:** Step selection MUST be by stable step name or index and MUST explain that earlier steps may be required to reconstruct state.
- **FR-8:** The CLI MUST return a non-zero exit code for invalid configuration, failed commands, missing prerequisites, or infrastructure errors, with distinct documented codes.
- **FR-9:** The CLI MUST support a non-interactive mode suitable for editors and scripts.
- **FR-10:** The CLI MUST print the workflow revision, selected image, working directory, and explicitly omitted CI-only inputs before execution.

### UX requirements

- **UX-1:** The default output MUST be concise, colored only on a capable terminal, and understandable without debug logs.
- **UX-2:** Every error MUST include a corrective next action when one is known.
- **UX-3:** Destructive file changes MUST be previewed or require explicit flags.
- **UX-4:** A `--verbose` mode MUST reveal normalized configuration and executor phases without exposing secrets.

### Operational requirements

- **OR-1:** The CLI SHOULD start validation within 200 ms on a typical development machine, excluding first-run runtime startup constraints to be measured.
- **OR-2:** Releases MUST provide checksums and a documented verification path.
- **OR-3:** CLI and server MUST report schema incompatibility clearly; they MUST NOT silently reinterpret unsupported versions.

## Proposed design

```text
robine init
robine validate [path] [--format human|json]
robine run [job-id] [--workflow path] [--no-deps]
robine run <job-id> --step <name-or-index>
robine version
```

The initial detectors target Elixir/Mix, Node package managers, and a generic fallback. Generated files use immutable image references when practical and include comments explaining mutable tags if a digest cannot be selected safely.

Local secrets are opt-in and never downloaded automatically from the server. A developer may provide an ignored local environment file through an explicit flag; the CLI warns if Git tracks that file.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Docker is unavailable | Prerequisite error with platform-specific check command | Start/install Docker and retry |
| Workflow is invalid | Source-located diagnostics; nothing executes | Correct errors and validate again |
| Requested job is unknown | Similar valid IDs are suggested | Choose an existing job |
| Local architecture differs | Warning identifies requested and actual platform | Use an appropriate machine or future remote runner |

## Security and privacy

The CLI does not transmit repository contents or telemetry by default. Secret files are explicit, local, and excluded from generated diagnostics. Any future telemetry MUST be opt-in and documented.

## Observability

Local debug logs contain version, platform, normalized non-secret configuration, executor phases, and error categories. They are written only when requested.

## Acceptance criteria

- [ ] `robine init` generates a valid workflow for a representative Elixir and Node repository without overwriting files.
- [ ] Every server-side invalid fixture produces the same diagnostic code through `robine validate`.
- [ ] A representative job has equivalent command, environment, workspace, image, and exit behavior locally and in CI.
- [ ] JSON output is stable enough for an editor integration fixture test.
- [ ] No default command sends repository or usage data externally.

## Open questions

- Choose CLI distribution formats and whether it is implemented as an Elixir escript, Burrito release, or another packaging strategy.
- Define exact behavior for running a single later step when prior filesystem state is absent.

## Out of scope / future work

- Remote control-plane administration, remote execution, editor extensions, and automatic secret synchronization.

