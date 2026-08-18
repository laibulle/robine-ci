# PROD-001 — MVP definition

## Status

- **State:** Accepted
- **Owner:** Product
- **Target:** MVP
- **Last updated:** 2026-08-08

## Summary

The MVP lets a developer install Robine CI on one Docker host, connect a trusted GitHub repository, and run a containerized workflow with excellent configuration feedback, live logs, GitHub status reporting, and local reproduction through the Robine CLI.

## Problem

GitHub Actions is convenient but proprietary and controlled by a single hosted platform. Existing open alternatives often demand significant platform knowledge or provide a fragmented developer experience. Small teams need an open system they can understand, operate, and reproduce locally without first building an internal platform.

## Goals

- A developer completes installation and a successful first pipeline in under ten minutes, excluding image download time.
- The same workflow and job have equivalent commands, image, environment rules, working directory, and exit behavior locally and in CI.
- A failed step is identifiable from the pipeline page without reading unrelated log output.
- The service survives process restarts without losing the durable state of accepted pipelines.
- All self-hosted features are available under AGPL-3.0-or-later.

## Non-goals

- Compatibility with GitHub Actions workflow files or third-party actions.
- Execution of untrusted public contributions.
- Remote, autoscaled, Kubernetes, macOS, or Windows runners.
- Deployment orchestration, environments, approvals, or release management.
- Git providers other than GitHub.
- A hosted Robine cloud offering in the MVP.

## Users and use cases

### Primary user

An individual developer or startup engineer who owns a trusted GitHub repository and can operate Docker Compose on a Linux host.

### Use cases

1. Install Robine CI and complete browser-based setup.
2. Connect a GitHub repository and receive a generated starter workflow.
3. Validate and run that workflow locally before pushing it.
4. Observe a pipeline live and diagnose a failed step.
5. Retry a failed job, cancel an active pipeline, or reproduce a job locally.

## Requirements

### Functional requirements

- **FR-1:** The MVP MUST support installation with Docker Compose on a single Linux host.
- **FR-2:** The MVP MUST support one or more trusted GitHub repositories through a GitHub App.
- **FR-3:** The MVP MUST discover all `.yml` and `.yaml` files directly under `.robine-ci/workflows/`.
- **FR-4:** The MVP MUST execute workflows using the semantics in WF-001 and EXEC-001.
- **FR-5:** Users MUST be able to cancel a pipeline and retry a failed or cancelled job.
- **FR-6:** The server MUST report pipeline status to GitHub.
- **FR-7:** The CLI MUST support workflow generation, validation, and local execution.

### UX requirements

- **UX-1:** Empty states MUST explain the next concrete action and provide a copyable command or configuration.
- **UX-2:** Errors MUST identify the affected workflow, job, step, and source line when that information exists.
- **UX-3:** Long-running operations MUST expose progress without requiring a page refresh.
- **UX-4:** The UI MUST not require knowledge of Elixir, OTP, or Docker internals for normal operation.

### Operational requirements

- **OR-1:** The supported MVP topology MUST fit on one host with PostgreSQL, the Robine server, and access to a Docker Engine.
- **OR-2:** The server SHOULD become ready within 30 seconds after its dependencies are healthy.
- **OR-3:** A webhook SHOULD be acknowledged within two seconds and processed asynchronously.
- **OR-4:** Pipeline state transitions MUST be durable before they are exposed to users or GitHub.

## Proposed design

The MVP is a vertical product slice with four first-class surfaces: Docker Compose installation, an Actix-rendered progressively enhanced web application, a native `robine` CLI, and Docker execution. UX quality is evaluated across the complete journey rather than treated as a separate presentation layer.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Invalid workflow | No pipeline starts; exact validation errors are shown | Fix and push, or run `robine validate` |
| Server restart | Durable pipelines retain their state | Scheduler reconciles non-terminal work |
| Runner/Docker unavailable | Job becomes blocked, then fails with a specific infrastructure reason | Restore Docker and retry the job |
| GitHub temporarily unavailable | Local state remains correct | Retry status delivery with backoff |

## Security and privacy

The MVP assumes repository code is trusted but still applies least privilege. Secrets are encrypted at rest, redacted from logs, and never supplied to workflows triggered from forks. Robine does not claim Docker containers provide a hostile-code security boundary.

## Observability

The service exposes structured application logs, health endpoints, webhook processing metrics, pipeline queue and duration metrics, and runner availability.

## Acceptance criteria

- [ ] A new operator follows documented steps from an empty host to a green GitHub check in under ten minutes, excluding external approvals and image downloads.
- [x] A developer can reproduce a failed CI job locally using a command shown in the web UI.
- [x] Restarting the server during a pipeline does not lose its recorded state.
- [x] Every non-user-actionable infrastructure failure has a distinct visible reason.

## Open questions

None blocking.

The external timing session follows `docs/acceptance/first-pipeline.md`. Release evidence is retained outside the public repository when it contains private tester or repository information and is schema-checked with `robine verify-acceptance` before this criterion is marked complete.

## Decisions

- The initial supported server hosts are Ubuntu Server 24.04 LTS and 26.04 LTS on x86-64 or ARM64, with Docker Engine 29.x and Docker Compose v2.
- Logs default to 30 days. Cache and artifact declarations default to seven days, subject to the quotas and retention rules in DATA-001.

## Out of scope / future work

- Remote runner fleets, additional forges, managed hosting, organizations, billing, and deployment workflows.
