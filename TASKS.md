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
- [x] Decide single Mix application versus umbrella. (One Mix/OTP application for the MVP.)
- [x] Select and document the architecture enforcement mechanism. (Focused ExUnit dependency checks run in CI.)
- [x] Finalize `Robine.ExecutionContext` and typed dependency construction.
- [x] Define the first durable outbox events. (`PipelineCreated` is the initial event.)
- [x] Resolve the read-query boundary convention. (Named query use cases exposed by facades.)
- [x] Mark PLAT-002 `Accepted` after blocking questions are closed.

### DEC-002 — Freeze workflow schema version 1

- **Spec:** [WF-001](docs/specs/workflows/wf-001-workflow-format.md)
- **Depends on:** DEC-001
- [x] Finalize cache checksum syntax without a general expression language. (`${{ checksum('relative/path') }}` is the sole interpolation and expands to a lowercase SHA-256 digest.)
- [x] Define workflow size, job count, step count, and graph-depth limits.
- [x] Decide mutable image tag policy. (Tags are accepted with a visible reproducibility warning; digests are recommended.)
- [x] Resolve shell behavior for images without `/bin/sh`. (`/bin/sh` and `/bin/bash` are the only v1 values; absence fails preparation as `shell_unavailable`.)
- [x] Publish valid and invalid YAML examples.
- [x] Mark WF-001 `Accepted`.

### DEC-003 — Freeze MVP operational defaults

- **Specs:** [PROD-001](docs/specs/product/prod-001-mvp-definition.md), [EXEC-001](docs/specs/execution/exec-001-local-docker-runner.md), [DATA-001](docs/specs/storage/data-001-cache-and-artifacts.md)
- **Depends on:** DEC-001
- [x] Select supported Linux and Docker Engine versions. (Ubuntu Server 24.04/26.04 LTS and Docker Engine 29.x.)
- [x] Define CPU, memory, process, job timeout, cancellation grace, concurrency, and disk-pressure defaults.
- [x] Define log, cache, and artifact retention and quotas. (30-day logs, seven-day cache/artifact declarations, 50 GiB instance and 10 GiB repository logical quotas.)
- [x] Choose archive format and compression. (TAR with gzip.)
- [x] Decide whether failed-job artifacts are retained by default. (Already-published artifacts keep their declared retention.)

### DEC-004 — Freeze identity and integration policy

- **Specs:** [IAM-001](docs/specs/identity/iam-001-authentication-and-sso.md), [GH-001](docs/specs/github/gh-001-github-integration.md)
- **Depends on:** DEC-001
- [x] Choose invite-only, verified-domain, or open OIDC provisioning. (Open provisioning requires a provider-verified email and grants viewer by default; collisions never auto-link.)
- [x] Define bootstrap token delivery and rotation. (`ROBINE_BOOTSTRAP_TOKEN`, hashed in memory, expires 15 minutes after startup, and becomes unusable after first-user creation.)
- [x] Decide whether repository-specific authorization is required for MVP. (Instance roles govern trusted repositories for MVP.)
- [x] Decide draft pull-request behavior. (Draft pull requests are ignored until `ready_for_review`.)
- [x] Confirm GitHub App permission set and GitHub Enterprise Server target. (GitHub.com only for MVP; repository permissions are Metadata read, Contents read, and Checks read/write; subscribed events are Push and Pull request.)

## Phase 1 — Repository and architecture foundation

### BOOT-001 — Bootstrap the Elixir/Phoenix project

- **Depends on:** DEC-001
- [x] Create the OTP application and Phoenix LiveView endpoint without generated business contexts.
- [x] Configure PostgreSQL, Tailwind, test environment, formatter, and deterministic local setup.
- [x] Add AGPL-3.0-or-later license and source headers policy if required.
- [x] Add `mix setup`, a full verification alias, and Docker Compose for application dependencies.
- [x] Document supported Elixir, Erlang/OTP, PostgreSQL, Node, and Docker versions.
- [x] Verify a clean source export can fetch dependencies, compile without Robine warnings, migrate, and pass the complete test suite without reused build artifacts.

### ARCH-001 — Implement clean-architecture primitives

- **Spec:** [PLAT-002](docs/specs/platform/plat-002-clean-application-architecture.md)
- **Depends on:** BOOT-001
- [x] Add typed `Robine.ExecutionContext` with actor, correlation, clock/ID, and dependency access.
- [x] Add `Robine.Runtime` composition root with startup validation.
- [x] Establish module/layout conventions for domain, use cases, ports, contracts, adapters, and delivery.
- [x] Add automated forbidden-dependency checks.
- [x] Add fixtures proving every forbidden direction fails.
- [x] Document temporary exception policy.

### ARCH-002 — Implement the reference vertical slice

- **Spec:** [PLAT-002](docs/specs/platform/plat-002-clean-application-architecture.md)
- **Depends on:** ARCH-001
- [x] Implement pipeline creation through structured input, facade `defdelegate`, use case, domain policy, ports, PostgreSQL adapters, durable GitHub delivery, and tests.
- [x] Demonstrate the same facade call from LiveView and a background worker (`list_pipelines/2`).
- [x] Provide a use-case unit test that starts no supervision tree or external service.
- [x] Add a reusable pipeline-repository port contract and PostgreSQL adapter integration tests.
- [x] Document the slice as the canonical implementation example.

### ARCH-003 — Implement durable work and outbox foundation

- **Specs:** [PLAT-001](docs/specs/platform/plat-001-system-architecture.md), [PLAT-002](docs/specs/platform/plat-002-clean-application-architecture.md)
- **Depends on:** ARCH-002
- [x] Select and configure the durable background-job mechanism.
- [x] Implement transaction-owned outbox persistence and idempotent delivery.
- [x] Implement correlation IDs, bounded retries, capped exponential backoff, dead-letter visibility, and reconciliation.
- [x] Prove committed events survive a missing worker job and are reconciled and delivered idempotently.
- [x] Expose queue, retry, outbox, and reconciliation health and telemetry.

## Phase 2 — Workflow and pipeline core

### WF-101 — Implement workflow parsing and source diagnostics

- **Spec:** [WF-001](docs/specs/workflows/wf-001-workflow-format.md)
- **Depends on:** DEC-002, ARCH-002
- [x] Parse workflow YAML without executing code or resolving network resources. (Directory discovery remains.)
- [x] Preserve source line and column information.
- [x] Reject unknown keys except preserved `x-` extensions.
- [x] Produce stable diagnostic codes. (Human and JSON renderers remain.)
- [x] Add a shared valid/invalid fixture corpus.

### WF-102 — Implement semantic validation and graph construction

- **Spec:** [WF-001](docs/specs/workflows/wf-001-workflow-format.md)
- **Depends on:** WF-101
- [x] Validate identifiers, steps, built-ins, dependencies, limits, image references, and environment values.
- [x] Detect cycles and report all relevant nodes.
- [x] Produce a deterministic normalized execution graph.
- [x] Ensure CLI and server use the same parser and validator.
- [x] Cover every WF-001 validation acceptance criterion.

### PIPE-101 — Implement pipeline lifecycle

- **Specs:** [PLAT-001](docs/specs/platform/plat-001-system-architecture.md), [PROD-001](docs/specs/product/prod-001-mvp-definition.md)
- **Depends on:** ARCH-003, WF-102
- [x] Model pipeline, job, attempt, and step states and valid transitions in the domain.
- [x] Persist exact immutable workflow revisions and normalized pipeline graphs transactionally.
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
- [x] Publish state changes only after durable commit through idempotent outbox projections.

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
- [x] Implement image pull, checkout, commands, timeouts, graceful/forced cancellation, and cleanup phases.
- [x] Stream separately identified, globally sequence-numbered stdout/stderr with demand-driven backpressure, independent streaming redaction, 64 KB chunks, and a 10 MB result cap.
- [x] Enforce global and repository concurrency and disk-pressure admission.
- [x] Reconcile labeled orphan containers and volumes after restart.

### EXEC-103 — Connect scheduler to local runner

- **Specs:** [PLAT-001](docs/specs/platform/plat-001-system-architecture.md), [EXEC-001](docs/specs/execution/exec-001-local-docker-runner.md)
- **Depends on:** PIPE-102, EXEC-102
- [x] Dispatch claimed attempts through the runner port with unique attempt resources.
- [x] Persist runner events before any future broadcast.
- [x] Implement leases, heartbeats, cancellation, timeout, retry, and runner-loss behavior.
- [x] Prove concurrent duplicate dispatch cannot create two active containers or delete the winner.
- [x] Add Docker phase-failure tests and simulate application interruption through orphan reconciliation.

## Phase 4 — Secrets, caches, and artifacts

### SEC-101 — Implement secret storage and policy

- **Spec:** [SEC-001](docs/specs/security/sec-001-secrets-and-trust-model.md)
- **Depends on:** ARCH-002, DEC-004
- [x] Select and review versioned AES-256-GCM with per-value nonces and authenticated metadata.
- [x] Implement repository and approved instance scopes, write-only API behavior, and audit events.
- [x] Require an external versioned master key and fail safely when it is unavailable.
- [x] Implement administrator-only, audited, cursor-resumable key rotation with mixed-version reads.
- [x] Enforce explicit references and no fork delivery.

### SEC-102 — Implement streaming secret redaction

- **Spec:** [SEC-001](docs/specs/security/sec-001-secrets-and-trust-model.md)
- **Depends on:** SEC-101, EXEC-102
- [x] Redact exact secrets across arbitrary log chunk boundaries before persistence or broadcast.
- [x] Define and test an inclusive 8-byte to 64-KiB value policy with literal, Base64, Base64url, and percent-encoded variants.
- [x] Ensure diagnostics, exceptions, telemetry, and debug inspection are redaction-safe.
- [x] Add adversarial fixture tests without production credentials.

### DATA-101 — Implement safe local blob storage

- **Spec:** [DATA-001](docs/specs/storage/data-001-cache-and-artifacts.md)
- **Depends on:** ARCH-002, DEC-003
- [x] Implement a local storage adapter with opaque object IDs and content digests.
- [x] Stream lazy binary chunks into hidden temporary objects with incremental size/digest enforcement and atomic finalization.
- [x] Enforce archive path, symlink, special-file, file-count, expanded-size, ratio, and time limits for source, cache, and artifact archives.
- [x] Implement quotas, retention, filesystem/database reconciliation, persistent reference-safe GC, and storage-pressure telemetry.

### DATA-102 — Implement caches and artifacts

- **Spec:** [DATA-001](docs/specs/storage/data-001-cache-and-artifacts.md)
- **Depends on:** DATA-101, EXEC-102
- [x] Implement exact-key cache restore and atomic cache save built-ins.
- [x] Implement immutable artifact upload/download with digest verification.
- [x] Enforce repository scoping and explicit dependency access.
- [x] Implement retry against retained dependency artifacts.
- [x] Refuse retries with precise rerun scope when required artifacts expired.

## Phase 5 — GitHub integration

### GH-101 — Implement GitHub App setup and credentials

- **Spec:** [GH-001](docs/specs/github/gh-001-github-integration.md)
- **Depends on:** DEC-004, SEC-101
- [x] Implement manifest-assisted setup or exact manual instructions.
- [x] Store private keys and webhook secrets as write-only encrypted instance credentials with environment bootstrap fallback.
- [x] Implement installation token lifecycle and live least-privilege permission diagnostics with exact corrective actions.
- [x] Expose integration health without leaking payload or credentials.

### GH-102 — Implement webhook ingestion

- **Spec:** [GH-001](docs/specs/github/gh-001-github-integration.md)
- **Depends on:** GH-101, PIPE-101
- [x] Verify signatures before processing.
- [x] Persist and acknowledge accepted deliveries before expensive work.
- [x] Deduplicate by delivery ID and tolerate reordered events.
- [x] Normalize supported push and pull-request events and filters.
- [x] Fetch workflow and source for the exact event SHA.
- [x] Disable fork execution and secret delivery by default.

### GH-103 — Implement GitHub checks projection

- **Spec:** [GH-001](docs/specs/github/gh-001-github-integration.md)
- **Depends on:** GH-102, PIPE-102
- [x] Create pipeline check suites and job check runs with stable Robine deep links. (GitHub creates the App/SHA check suite automatically when Robine creates its pipeline and job check runs.)
- [x] Deliver updates idempotently through the outbox using stable external keys and persisted provider IDs.
- [x] Retry with bounded exponential backoff and jitter.
- [x] Reconcile stale or missing checks after GitHub outages.
- [x] Monitor sanitized GitHub API outcomes, latency, and rate-limit state in telemetry and operator health.

## Phase 6 — CLI developer experience

### CLI-101 — Package the Robine CLI

- **Spec:** [CLI-001](docs/specs/cli/cli-001-local-developer-experience.md)
- **Depends on:** BOOT-001
- [x] Choose a cross-platform packaging strategy and supported platforms. (Elixir escript for the MVP; requires a compatible Erlang runtime.)
- [x] Implement version reporting, deterministic SHA-256 manifests, cross-platform verification instructions, stable exit-code classes, and non-interactive output.
- [x] Ensure the CLI does not transmit repository data or telemetry by default.

### CLI-102 — Implement init and validation

- **Spec:** [CLI-001](docs/specs/cli/cli-001-local-developer-experience.md)
- **Depends on:** CLI-101, WF-102
- [x] Detect Elixir/Mix and Node projects without executing repository code.
- [x] Preview generated workflows and protect existing files from overwrite.
- [x] Implement human and stable JSON validation output.
- [x] Prove the CLI and server produce identical diagnostics from the fixture corpus.

### CLI-103 — Implement local execution

- **Spec:** [CLI-001](docs/specs/cli/cli-001-local-developer-experience.md)
- **Depends on:** CLI-101, EXEC-102, DATA-102
- [x] Run a workflow, selected job with dependencies, or selected step.
- [x] Use the same normalized execution contract and local Docker adapter as CI.
- [x] Show image, working directory, revision, and omitted CI-only inputs.
- [x] Support explicit Git-ignored local secret files with declaration filtering, shared masking bounds, and no server-side secret download.
- [x] Prove command, environment, workspace, image, timeout, output, and success/failure exit equivalence with shared CI/local Docker fixtures.

## Phase 7 — Identity and complete web experience

### IAM-101 — Implement bootstrap, sessions, and authorization

- **Spec:** [IAM-001](docs/specs/identity/iam-001-authentication-and-sso.md)
- **Depends on:** ARCH-002, DEC-004
- [x] Implement one-time expiring first-admin bootstrap.
- [x] Implement memory-hard local credentials, secure sessions, revocation, and login rate limits.
- [x] Implement administrator, maintainer, and viewer policies inside application use cases.
- [x] Prevent removal of the last usable administrator.
- [x] Provide an explicit break-glass local administrator path.

### IAM-102 — Implement OIDC SSO

- **Spec:** [IAM-001](docs/specs/identity/iam-001-authentication-and-sso.md)
- **Depends on:** IAM-101
- [x] Implement authorization code flow with PKCE, state, nonce, issuer, audience, and signature validation.
- [x] Implement metadata/JWKS refresh and bounded clock skew.
- [x] Link identities by issuer and subject, never silently by email alone.
- [x] Add provider preflight test and exact redirect URI guidance.
- [x] Test provider outage and break-glass recovery, including failed authorization and callback, no partial identity/session, and local administrator access during the incident.

### WEB-101 — Implement setup and administration

- **Specs:** [WEB-001](docs/specs/web/web-001-pipeline-experience.md), [IAM-001](docs/specs/identity/iam-001-authentication-and-sso.md)
- **Depends on:** IAM-102, GH-101, SEC-101
- [x] Define semantic Tailwind design tokens and accessible base-component contracts for focus, motion, forms, alerts, tables, themes, and non-color-only statuses.
- [x] Build first-run, sign-in, live GitHub installation/repository selection, secrets, identity, retention, and instance-health pages.
- [x] Design shared empty, loading, disconnected, degraded, and error states with distinct recovery copy and assistive semantics.
- [x] Enforce server-side authorization for every route and LiveView event, with route-role and forged hidden-event tests.

### WEB-102 — Implement repository and pipeline views

- **Spec:** [WEB-001](docs/specs/web/web-001-pipeline-experience.md)
- **Depends on:** WEB-101, EXEC-103, GH-103
- [x] Build repository, immutable workflow-revision, pipeline-history, pipeline-detail, and job-detail pages.
- [x] Display the accessible dependency graph/list, status, trigger, actor, exact commit, runner phases, durable duration, and distinct infrastructure failures.
- [x] Implement authorized cancellation and job retry with confirmation.
- [x] Show copyable local reproduction commands and omitted CI-only inputs.
- [x] Preserve stable deep links across state changes.

### WEB-103 — Implement scalable live logs

- **Spec:** [WEB-001](docs/specs/web/web-001-pipeline-experience.md)
- **Depends on:** WEB-102, SEC-102
- [x] Persist and request logs by sequence cursor.
- [x] Reconnect without duplicate or missing chunks.
- [x] Group persisted logs explicitly by runner phase and step with accessible expand/collapse, bounded search, and stable phase/step/segment deep links.
- [x] Sanitize ANSI output before HTML rendering.
- [x] Avoid loading complete logs into a LiveView process or browser DOM.
- [x] Pass an exact 100 MB bounded navigation test and automated semantic accessibility smoke checks for core journeys.

## Phase 8 — MVP hardening and release

### OPS-101 — Complete observability and health

- **Depends on:** EXEC-103, GH-103, WEB-103
- [x] Implement allowlisted redaction-safe structured events and persist correlation across webhook, GitHub delivery, pipeline, job, attempt, API, and local runner boundaries.
- [x] Expose readiness/liveness and dependency health without leaking secrets.
- [x] Implement the metrics required by every MVP specification through a token-protected Prometheus exporter with bounded-label contract tests.
- [x] Document alerts for queue backlog, runner loss, storage pressure, outbox failure, GitHub degradation, and authentication anomalies.

### QA-101 — Verify resilience and security contracts

- **Depends on:** OPS-101, DATA-102, IAM-102
- [x] Test durable state recovery through a fresh runtime graph and Docker restart recovery through labeled orphan reconciliation.
- [x] Test duplicate dispatch, duplicate/reordered webhook delivery, lease expiry, cancellation, timeout, and outbox retries.
- [x] Test archive attacks, log injection, secret leakage, authorization boundaries, OIDC account collision, and fork policy.
- [x] Run architecture checks, compiler-as-static-analysis, Sobelow, MixAudit, Hex retirement audit, unused-dependency checks, and the complete test suite through `mix qa`.
- [ ] Resolve every applicable unchecked acceptance criterion in accepted specs.

### DX-101 — Verify the ten-minute first pipeline

- **Spec:** [PROD-001](docs/specs/product/prod-001-mvp-definition.md)
- **Depends on:** QA-101, CLI-103, WEB-103
- [x] Test documented installation from a clean supported Linux host.
- [ ] Reach a green GitHub check in under ten minutes, excluding approvals and image downloads.
- [x] Reproduce a representative failed CI job locally from the command shown in the UI.
- [ ] Conduct accessibility and first-use tests with developers unfamiliar with the implementation.
- [x] Fix or explicitly re-specify every material failure discovered.

### REL-101 — Prepare the first open-source release

- **Depends on:** DX-101
- [x] Confirm the complete AGPL-3.0-or-later text and a test-enforced locked third-party notice inventory.
- [x] Publish installation, upgrade, backup, recovery, security-model, and troubleshooting documentation.
- [x] Document supported versions, retention defaults, limitations, and trusted-repository assumptions.
- [x] Produce and verify checksummed server and CLI 0.1.0 artifacts, including license material in the server archive.
- [x] Publish a forward-migration and backup-restore rollback procedure.
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
