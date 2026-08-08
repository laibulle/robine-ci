# Robine CI implementation plan

This file orders implementation work for the MVP. Product behavior and architecture are defined in [docs/specs](docs/specs/README.md). A checkbox means the task and all of its exit criteria have been verified, not merely started.

## Status legend

- `[ ]` Ready or not started
- `[~]` In progress; include an owner and short note
- `[x]` Complete and verified
- `[!]` Blocked; name the blocking decision or dependency

Only one status marker belongs on a task. Complete dependencies before starting a dependent task unless the task explicitly permits parallel work.

## Phase 0 — Resolve blocking decisions

### DEC-001 — Accept the application architecture

- **Spec:** [PLAT-002](docs/specs/platform/plat-002-clean-application-architecture.md)
- **Depends on:** None
- [ ] Decide single Mix application versus umbrella; default to a single application.
- [ ] Select and document the compile-time architecture enforcement mechanism.
- [ ] Finalize `Robine.ExecutionContext` and typed dependency construction.
- [ ] Define the first durable outbox events.
- [ ] Resolve the read-query boundary convention.
- [ ] Mark PLAT-002 `Accepted` after blocking questions are closed.

### DEC-002 — Freeze workflow schema version 1

- **Spec:** [WF-001](docs/specs/workflows/wf-001-workflow-format.md)
- **Depends on:** DEC-001
- [ ] Finalize cache checksum syntax without a general expression language.
- [ ] Define workflow size, job count, step count, and graph-depth limits.
- [ ] Decide mutable image tag policy.
- [ ] Resolve shell behavior for images without `/bin/sh`.
- [ ] Publish valid and invalid YAML examples.
- [ ] Mark WF-001 `Accepted`.

### DEC-003 — Freeze MVP operational defaults

- **Specs:** [PROD-001](docs/specs/product/prod-001-mvp-definition.md), [EXEC-001](docs/specs/execution/exec-001-local-docker-runner.md), [DATA-001](docs/specs/storage/data-001-cache-and-artifacts.md)
- **Depends on:** DEC-001
- [ ] Select supported Linux and Docker Engine versions.
- [ ] Define CPU, memory, job timeout, cancellation grace, concurrency, and disk-pressure defaults.
- [ ] Define log, cache, and artifact retention and quotas.
- [ ] Choose archive format and compression.
- [ ] Decide whether failed-job artifacts are retained by default.

### DEC-004 — Freeze identity and integration policy

- **Specs:** [IAM-001](docs/specs/identity/iam-001-authentication-and-sso.md), [GH-001](docs/specs/github/gh-001-github-integration.md)
- **Depends on:** DEC-001
- [ ] Choose invite-only, verified-domain, or open OIDC provisioning.
- [ ] Define bootstrap token delivery and rotation.
- [ ] Decide whether repository-specific authorization is required for MVP.
- [ ] Decide draft pull-request behavior.
- [ ] Confirm GitHub App permission set and GitHub Enterprise Server target.

## Phase 1 — Repository and architecture foundation

### BOOT-001 — Bootstrap the Elixir/Phoenix project

- **Depends on:** DEC-001
- [x] Create the OTP application and Phoenix LiveView endpoint without generated business contexts.
- [x] Configure PostgreSQL, Tailwind, test environment, formatter, and deterministic local setup.
- [x] Add AGPL-3.0-or-later license and source headers policy if required.
- [x] Add `mix setup`, a full verification alias, and Docker Compose for application dependencies.
- [x] Document supported Elixir, Erlang/OTP, PostgreSQL, Node, and Docker versions.
- [ ] Verify a clean checkout can compile and run tests.

### ARCH-001 — Implement clean-architecture primitives

- **Spec:** [PLAT-002](docs/specs/platform/plat-002-clean-application-architecture.md)
- **Depends on:** BOOT-001
- [x] Add typed `Robine.ExecutionContext` with actor, correlation, clock/ID, and dependency access.
- [x] Add `Robine.Runtime` composition root with startup validation.
- [x] Establish module/layout conventions for domain, use cases, ports, contracts, adapters, and delivery.
- [x] Add automated forbidden-dependency checks.
- [ ] Add fixtures proving every forbidden direction fails.
- [ ] Document temporary exception policy.

### ARCH-002 — Implement the reference vertical slice

- **Spec:** [PLAT-002](docs/specs/platform/plat-002-clean-application-architecture.md)
- **Depends on:** ARCH-001
- [ ] Implement one small pipeline operation through command, facade `defdelegate`, use case, domain policy, port, PostgreSQL adapter, delivery adapter, and tests. (Facade, use case, domain, ports, PostgreSQL, and tests exist; delivery adapters remain.)
- [ ] Demonstrate the same facade call from LiveView and a background worker.
- [x] Provide a use-case unit test that starts no supervision tree or external service.
- [ ] Add port contract and adapter integration tests. (PostgreSQL integration exists; shared port contracts remain.)
- [ ] Document the slice as the canonical implementation example.

### ARCH-003 — Implement durable work and outbox foundation

- **Specs:** [PLAT-001](docs/specs/platform/plat-001-system-architecture.md), [PLAT-002](docs/specs/platform/plat-002-clean-application-architecture.md)
- **Depends on:** ARCH-002
- [x] Select and configure the durable background-job mechanism.
- [x] Implement transaction-owned outbox persistence and idempotent delivery.
- [ ] Implement correlation IDs, bounded retries, backoff, dead-letter visibility, and reconciliation.
- [ ] Prove committed events survive worker and application crashes.
- [ ] Expose queue, retry, outbox, and reconciliation telemetry.

## Phase 2 — Workflow and pipeline core

### WF-101 — Implement workflow parsing and source diagnostics

- **Spec:** [WF-001](docs/specs/workflows/wf-001-workflow-format.md)
- **Depends on:** DEC-002, ARCH-002
- [x] Parse workflow YAML without executing code or resolving network resources. (Directory discovery remains.)
- [ ] Preserve source line and column information.
- [x] Reject unknown keys except preserved `x-` extensions.
- [x] Produce stable diagnostic codes. (Human and JSON renderers remain.)
- [ ] Add a shared valid/invalid fixture corpus.

### WF-102 — Implement semantic validation and graph construction

- **Spec:** [WF-001](docs/specs/workflows/wf-001-workflow-format.md)
- **Depends on:** WF-101
- [ ] Validate identifiers, steps, built-ins, dependencies, limits, image references, and environment values. (Limits and some built-in inputs remain.)
- [x] Detect cycles and report all relevant nodes.
- [x] Produce a deterministic normalized execution graph.
- [ ] Ensure CLI and server use the same parser and validator.
- [ ] Cover every WF-001 validation acceptance criterion.

### PIPE-101 — Implement pipeline lifecycle

- **Specs:** [PLAT-001](docs/specs/platform/plat-001-system-architecture.md), [PROD-001](docs/specs/product/prod-001-mvp-definition.md)
- **Depends on:** ARCH-003, WF-102
- [x] Model pipeline, job, attempt, and step states and valid transitions in the domain.
- [ ] Persist workflow revisions and pipeline graphs transactionally. (Pipeline graphs are atomic; workflow revision persistence remains.)
- [x] Implement create, queue, cancel, record-event, and reconcile use cases.
- [x] Give every attempt an idempotency token and lease semantics.
- [x] Distinguish user command failures, cancellation, timeout, runner loss, and system failures.
- [x] Verify duplicate and reordered events cannot corrupt state.

### PIPE-102 — Implement scheduler and dependency release

- **Specs:** [PLAT-001](docs/specs/platform/plat-001-system-architecture.md), [WF-001](docs/specs/workflows/wf-001-workflow-format.md)
- **Depends on:** PIPE-101
- [x] Transactionally claim ready jobs without exceeding concurrency limits.
- [x] Release jobs only after all declared dependencies succeed.
- [x] Apply backpressure and fair repository-level limits.
- [x] Reconcile abandoned claims and expired leases.
- [ ] Publish state changes only after durable commit.

## Phase 3 — Local Docker execution

### EXEC-101 — Implement normalized execution specification

- **Specs:** [EXEC-001](docs/specs/execution/exec-001-local-docker-runner.md), [PLAT-002](docs/specs/platform/plat-002-clean-application-architecture.md)
- **Depends on:** WF-102, ARCH-002
- [x] Define a versioned, framework-free execution contract shared by server, runner, and CLI.
- [x] Represent image, workspace, shell, environment, steps, timeout, built-ins, and secret references explicitly.
- [x] Validate execution contracts at adapter boundaries.
- [x] Ensure no Ecto, Phoenix, Docker-client, or secret plaintext types leak into persisted public metadata.

### EXEC-102 — Implement local Docker runner adapter

- **Spec:** [EXEC-001](docs/specs/execution/exec-001-local-docker-runner.md)
- **Depends on:** EXEC-101, DEC-003
- [x] Implement fresh job containers and workspaces with sequential shared-state steps.
- [x] Drop capabilities and exclude privileged mode, host networking, Docker socket, devices, and host-path mounts from the execution contract.
- [ ] Implement image pull, checkout, commands, timeouts, graceful/forced cancellation, and cleanup phases. (Image pull, commands, timeout, and cleanup exist; checkout and externally requested cancellation remain.)
- [ ] Stream sequence-numbered stdout/stderr with bounded memory.
- [ ] Enforce global and repository concurrency and disk-pressure admission.
- [ ] Reconcile labeled orphan containers and volumes after restart.

### EXEC-103 — Connect scheduler to local runner

- **Specs:** [PLAT-001](docs/specs/platform/plat-001-system-architecture.md), [EXEC-001](docs/specs/execution/exec-001-local-docker-runner.md)
- **Depends on:** PIPE-102, EXEC-102
- [x] Dispatch claimed attempts through the runner port with unique attempt resources.
- [x] Persist runner events before any future broadcast.
- [ ] Implement leases, heartbeats, cancellation, timeout, retry, and runner-loss behavior. (Leases, timeout classification, Oban retry, and runner loss exist; heartbeat and live cancellation remain.)
- [ ] Prove duplicate dispatch cannot create two active containers.
- [ ] Add failure-injection tests for Docker and application restarts.

## Phase 4 — Secrets, caches, and artifacts

### SEC-101 — Implement secret storage and policy

- **Spec:** [SEC-001](docs/specs/security/sec-001-secrets-and-trust-model.md)
- **Depends on:** ARCH-002, DEC-004
- [ ] Select and review the authenticated-encryption construction.
- [ ] Implement repository and approved instance scopes, write-only API behavior, and audit events.
- [ ] Require an external versioned master key and fail safely when it is unavailable.
- [ ] Implement resumable key rotation.
- [ ] Enforce explicit references and no fork delivery.

### SEC-102 — Implement streaming secret redaction

- **Spec:** [SEC-001](docs/specs/security/sec-001-secrets-and-trust-model.md)
- **Depends on:** SEC-101, EXEC-102
- [ ] Redact exact secrets across arbitrary log chunk boundaries before persistence or broadcast.
- [ ] Define and test minimum/maximum size and encoded-variant policy.
- [ ] Ensure diagnostics, exceptions, telemetry, and debug inspection are redaction-safe.
- [ ] Add adversarial fixture tests without production credentials.

### DATA-101 — Implement safe local blob storage

- **Spec:** [DATA-001](docs/specs/storage/data-001-cache-and-artifacts.md)
- **Depends on:** ARCH-002, DEC-003
- [ ] Implement a local storage adapter with opaque object IDs and content digests.
- [ ] Stream into temporary objects and finalize atomically.
- [ ] Enforce archive path, symlink, special-file, file-count, expanded-size, ratio, and time limits.
- [ ] Implement quotas, retention, reconciliation, and storage-pressure telemetry.

### DATA-102 — Implement caches and artifacts

- **Spec:** [DATA-001](docs/specs/storage/data-001-cache-and-artifacts.md)
- **Depends on:** DATA-101, EXEC-102
- [ ] Implement exact-key cache restore and atomic cache save built-ins.
- [ ] Implement immutable artifact upload/download with digest verification.
- [ ] Enforce repository scoping and explicit dependency access.
- [ ] Implement retry against retained dependency artifacts.
- [ ] Refuse retries with precise rerun scope when required artifacts expired.

## Phase 5 — GitHub integration

### GH-101 — Implement GitHub App setup and credentials

- **Spec:** [GH-001](docs/specs/github/gh-001-github-integration.md)
- **Depends on:** DEC-004, SEC-101
- [ ] Implement manifest-assisted setup or exact manual instructions.
- [ ] Store private keys and webhook secrets encrypted.
- [ ] Implement installation token lifecycle and least-privilege permission diagnostics.
- [ ] Expose integration health without leaking payload or credentials.

### GH-102 — Implement webhook ingestion

- **Spec:** [GH-001](docs/specs/github/gh-001-github-integration.md)
- **Depends on:** GH-101, PIPE-101
- [ ] Verify signatures before processing.
- [ ] Persist and acknowledge accepted deliveries before expensive work.
- [ ] Deduplicate by delivery ID and tolerate reordered events.
- [ ] Normalize supported push and pull-request events and filters.
- [ ] Fetch workflow and source for the exact event SHA.
- [ ] Disable fork execution and secret delivery by default.

### GH-103 — Implement GitHub checks projection

- **Spec:** [GH-001](docs/specs/github/gh-001-github-integration.md)
- **Depends on:** GH-102, PIPE-102
- [ ] Create pipeline check suites and job check runs with stable Robine deep links.
- [ ] Deliver updates idempotently through the outbox.
- [ ] Retry with bounded exponential backoff and jitter.
- [ ] Reconcile stale or missing checks after GitHub outages.
- [ ] Monitor API errors and rate limits.

## Phase 6 — CLI developer experience

### CLI-101 — Package the Robine CLI

- **Spec:** [CLI-001](docs/specs/cli/cli-001-local-developer-experience.md)
- **Depends on:** BOOT-001
- [ ] Choose a cross-platform packaging strategy and supported platforms.
- [ ] Implement version reporting, checksums, verification instructions, stable exit-code classes, and non-interactive output.
- [ ] Ensure the CLI does not transmit repository data or telemetry by default.

### CLI-102 — Implement init and validation

- **Spec:** [CLI-001](docs/specs/cli/cli-001-local-developer-experience.md)
- **Depends on:** CLI-101, WF-102
- [ ] Detect Elixir/Mix and Node projects without executing repository code.
- [ ] Preview generated workflows and protect existing files from overwrite.
- [ ] Implement human and stable JSON validation output.
- [ ] Prove the CLI and server produce identical diagnostics from the fixture corpus.

### CLI-103 — Implement local execution

- **Spec:** [CLI-001](docs/specs/cli/cli-001-local-developer-experience.md)
- **Depends on:** CLI-101, EXEC-102, DATA-102
- [ ] Run a workflow, selected job with dependencies, or selected step.
- [ ] Use the same normalized execution contract and local Docker adapter as CI.
- [ ] Show image, working directory, revision, and omitted CI-only inputs.
- [ ] Support explicit ignored local secret files without server-side secret download.
- [ ] Prove command, environment, workspace, image, and exit equivalence with CI fixtures.

## Phase 7 — Identity and complete web experience

### IAM-101 — Implement bootstrap, sessions, and authorization

- **Spec:** [IAM-001](docs/specs/identity/iam-001-authentication-and-sso.md)
- **Depends on:** ARCH-002, DEC-004
- [ ] Implement one-time expiring first-admin bootstrap.
- [ ] Implement memory-hard local credentials, secure sessions, revocation, and login rate limits.
- [ ] Implement administrator, maintainer, and viewer policies inside application use cases.
- [ ] Prevent removal of the last usable administrator.
- [ ] Provide an explicit break-glass local administrator path.

### IAM-102 — Implement OIDC SSO

- **Spec:** [IAM-001](docs/specs/identity/iam-001-authentication-and-sso.md)
- **Depends on:** IAM-101
- [ ] Implement authorization code flow with PKCE, state, nonce, issuer, audience, and signature validation.
- [ ] Implement metadata/JWKS refresh and bounded clock skew.
- [ ] Link identities by issuer and subject, never silently by email alone.
- [ ] Add provider preflight test and exact redirect URI guidance.
- [ ] Test provider outage and break-glass recovery.

### WEB-101 — Implement setup and administration

- **Specs:** [WEB-001](docs/specs/web/web-001-pipeline-experience.md), [IAM-001](docs/specs/identity/iam-001-authentication-and-sso.md)
- **Depends on:** IAM-102, GH-101, SEC-101
- [ ] Define Tailwind design tokens and accessible base components.
- [ ] Build first-run, sign-in, repository selection, secrets, identity, retention, and instance-health pages.
- [ ] Design every empty, loading, disconnected, degraded, and error state.
- [ ] Enforce server-side authorization for routes and LiveView events.

### WEB-102 — Implement repository and pipeline views

- **Spec:** [WEB-001](docs/specs/web/web-001-pipeline-experience.md)
- **Depends on:** WEB-101, EXEC-103, GH-103
- [ ] Build repository, workflow, pipeline-history, pipeline-detail, and job-detail pages.
- [ ] Display dependency graph/list, status, trigger, actor, commit, phases, duration, and infrastructure failures.
- [ ] Implement authorized cancellation and job retry with confirmation.
- [ ] Show copyable local reproduction commands and omitted CI-only inputs.
- [ ] Preserve stable deep links across state changes.

### WEB-103 — Implement scalable live logs

- **Spec:** [WEB-001](docs/specs/web/web-001-pipeline-experience.md)
- **Depends on:** WEB-102, SEC-102
- [ ] Persist and request logs by sequence cursor.
- [ ] Reconnect without duplicate or missing chunks.
- [ ] Group by phase and step with expand, collapse, search, and deep links.
- [ ] Sanitize ANSI output before HTML rendering.
- [ ] Avoid loading complete logs into a LiveView process or browser DOM.
- [ ] Pass the 100 MB navigation criterion and accessibility checks.

## Phase 8 — MVP hardening and release

### OPS-101 — Complete observability and health

- **Depends on:** EXEC-103, GH-103, WEB-103
- [ ] Implement structured redaction-safe logs and correlation across webhook, pipeline, job, attempt, runner, and GitHub delivery.
- [ ] Expose readiness/liveness and dependency health without leaking secrets.
- [ ] Implement the metrics required by every MVP specification.
- [ ] Document alerts for queue backlog, runner loss, storage pressure, outbox failure, GitHub degradation, and authentication anomalies.

### QA-101 — Verify resilience and security contracts

- **Depends on:** OPS-101, DATA-102, IAM-102
- [ ] Test application and Docker restart recovery during active work.
- [ ] Test duplicate dispatch, duplicate/reordered webhook delivery, lease expiry, cancellation, timeout, and outbox retries.
- [ ] Test archive attacks, log injection, secret leakage, authorization boundaries, OIDC account collision, and fork policy.
- [ ] Run architecture checks, static analysis, dependency audit, and complete test suite.
- [ ] Resolve every applicable unchecked acceptance criterion in accepted specs.

### DX-101 — Verify the ten-minute first pipeline

- **Spec:** [PROD-001](docs/specs/product/prod-001-mvp-definition.md)
- **Depends on:** QA-101, CLI-103, WEB-103
- [ ] Test documented installation from a clean supported Linux host.
- [ ] Reach a green GitHub check in under ten minutes, excluding approvals and image downloads.
- [ ] Reproduce a representative failed CI job locally from the command shown in the UI.
- [ ] Conduct accessibility and first-use tests with developers unfamiliar with the implementation.
- [ ] Fix or explicitly re-specify every material failure discovered.

### REL-101 — Prepare the first open-source release

- **Depends on:** DX-101
- [ ] Confirm AGPL licensing and third-party notices.
- [ ] Publish installation, upgrade, backup, recovery, security-model, and troubleshooting documentation.
- [ ] Document supported versions, retention defaults, limitations, and trusted-repository assumptions.
- [ ] Produce signed or checksummed server and CLI artifacts.
- [ ] Publish a migration and rollback procedure.
- [ ] Tag the release only after all MVP acceptance criteria are verified.

## Post-MVP backlog

These items are intentionally unordered and must receive specifications before implementation:

- [ ] Remote runner enrollment over authenticated HTTPS/WebSocket.
- [ ] Runner labels, capabilities, autoscaling, and fleet administration.
- [ ] S3-compatible artifact and cache storage.
- [ ] GitLab, Forgejo/Gitea, and additional source-control providers.
- [ ] Service containers and richer workflow conditions.
- [ ] Matrices, reusable workflows, manual inputs, and scheduled triggers.
- [ ] Micro-VM isolation for untrusted workloads.
- [ ] Managed Robine cloud and commercial support operations.
- [ ] SAML, LDAP, SCIM, and identity group mapping.
- [ ] Deployment environments, approvals, and release workflows.
