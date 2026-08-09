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
- [ ] Verify a clean checkout can compile and run tests.

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
- [x] Implement image pull, checkout, commands, timeouts, graceful/forced cancellation, and cleanup phases.
- [ ] Stream sequence-numbered stdout/stderr with bounded memory. (Redacted combined output streams during execution with database backpressure and a 10 MB result cap; preserving stdout/stderr as separate channels remains.)
- [x] Enforce global and repository concurrency and disk-pressure admission.
- [x] Reconcile labeled orphan containers and volumes after restart.

### EXEC-103 — Connect scheduler to local runner

- **Specs:** [PLAT-001](docs/specs/platform/plat-001-system-architecture.md), [EXEC-001](docs/specs/execution/exec-001-local-docker-runner.md)
- **Depends on:** PIPE-102, EXEC-102
- [x] Dispatch claimed attempts through the runner port with unique attempt resources.
- [x] Persist runner events before any future broadcast.
- [x] Implement leases, heartbeats, cancellation, timeout, retry, and runner-loss behavior.
- [ ] Prove duplicate dispatch cannot create two active containers.
- [ ] Add failure-injection tests for Docker and application restarts.

## Phase 4 — Secrets, caches, and artifacts

### SEC-101 — Implement secret storage and policy

- **Spec:** [SEC-001](docs/specs/security/sec-001-secrets-and-trust-model.md)
- **Depends on:** ARCH-002, DEC-004
- [ ] Select and review the authenticated-encryption construction. (AES-256-GCM with per-value nonces and authenticated metadata is implemented; focused security review remains.)
- [x] Implement repository and approved instance scopes, write-only API behavior, and audit events.
- [x] Require an external versioned master key and fail safely when it is unavailable.
- [ ] Implement resumable key rotation.
- [x] Enforce explicit references and no fork delivery.

### SEC-102 — Implement streaming secret redaction

- **Spec:** [SEC-001](docs/specs/security/sec-001-secrets-and-trust-model.md)
- **Depends on:** SEC-101, EXEC-102
- [x] Redact exact secrets across arbitrary log chunk boundaries before persistence or broadcast.
- [ ] Define and test minimum/maximum size and encoded-variant policy. (Eight-byte minimum and Base64 variants are tested; maximum and additional encodings remain.)
- [ ] Ensure diagnostics, exceptions, telemetry, and debug inspection are redaction-safe.
- [x] Add adversarial fixture tests without production credentials.

### DATA-101 — Implement safe local blob storage

- **Spec:** [DATA-001](docs/specs/storage/data-001-cache-and-artifacts.md)
- **Depends on:** ARCH-002, DEC-003
- [x] Implement a local storage adapter with opaque object IDs and content digests.
- [ ] Stream into temporary objects and finalize atomically. (Temporary same-filesystem publication is atomic; streaming input remains.)
- [x] Enforce archive path, symlink, special-file, file-count, expanded-size, ratio, and time limits for source, cache, and artifact archives.
- [ ] Implement quotas, retention, reconciliation, and storage-pressure telemetry. (Atomic instance/repository logical quotas and hourly bounded retention with persistent, reference-safe blob GC are implemented; full filesystem reconciliation and pressure telemetry remain.)

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
- [ ] Store private keys and webhook secrets encrypted. (MVP credentials are supplied out-of-band through environment variables and never persisted; encrypted UI-managed credentials remain.)
- [ ] Implement installation token lifecycle and least-privilege permission diagnostics. (JWT exchange, expiration-aware caching, and documented least-privilege permissions exist; live permission diagnostics remain.)
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
- [ ] Deliver updates idempotently through the outbox. (Provider IDs and stable external keys make updates idempotent; check updates currently use Oban rather than the domain outbox.)
- [x] Retry with bounded exponential backoff and jitter.
- [x] Reconcile stale or missing checks after GitHub outages.
- [ ] Monitor API errors and rate limits.

## Phase 6 — CLI developer experience

### CLI-101 — Package the Robine CLI

- **Spec:** [CLI-001](docs/specs/cli/cli-001-local-developer-experience.md)
- **Depends on:** BOOT-001
- [x] Choose a cross-platform packaging strategy and supported platforms. (Elixir escript for the MVP; requires a compatible Erlang runtime.)
- [ ] Implement version reporting, checksums, verification instructions, stable exit-code classes, and non-interactive output. (Version, documented exit classes in code, and non-interactive execution exist; release checksums and verification docs remain.)
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
- [ ] Support explicit ignored local secret files without server-side secret download. (Local cache and artifact built-ins run without server access; explicit secret files remain.)
- [ ] Prove command, environment, workspace, image, and exit equivalence with CI fixtures. (A Docker-backed multi-job cache/artifact fixture proves core local data semantics; the full equivalence corpus remains.)

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
- [ ] Test provider outage and break-glass recovery. (The paths are independent and errors preserve local sign-in; explicit outage integration coverage remains.)

### WEB-101 — Implement setup and administration

- **Specs:** [WEB-001](docs/specs/web/web-001-pipeline-experience.md), [IAM-001](docs/specs/identity/iam-001-authentication-and-sso.md)
- **Depends on:** IAM-102, GH-101, SEC-101
- [ ] Define Tailwind design tokens and accessible base components. (Responsive navigation, status labels, semantic tables, alerts, and form components exist; the documented token layer remains.)
- [ ] Build first-run, sign-in, repository selection, secrets, identity, retention, and instance-health pages. (First-run, sign-in, repository browsing, write-only secrets, identity administration, retention controls, and instance health are complete; installation selection remains.)
- [ ] Design every empty, loading, disconnected, degraded, and error state.
- [ ] Enforce server-side authorization for routes and LiveView events. (Authenticated pipeline routes use a server-side on-mount hook; future administration routes and events remain.)

### WEB-102 — Implement repository and pipeline views

- **Spec:** [WEB-001](docs/specs/web/web-001-pipeline-experience.md)
- **Depends on:** WEB-101, EXEC-103, GH-103
- [ ] Build repository, workflow, pipeline-history, pipeline-detail, and job-detail pages. (Repository, workflow summaries, pipeline history/detail, and job detail exist; a dedicated workflow revision page remains.)
- [ ] Display dependency graph/list, status, trigger, actor, commit, phases, duration, and infrastructure failures.
- [x] Implement authorized cancellation and job retry with confirmation.
- [x] Show copyable local reproduction commands and omitted CI-only inputs.
- [x] Preserve stable deep links across state changes.

### WEB-103 — Implement scalable live logs

- **Spec:** [WEB-001](docs/specs/web/web-001-pipeline-experience.md)
- **Depends on:** WEB-102, SEC-102
- [x] Persist and request logs by sequence cursor.
- [x] Reconnect without duplicate or missing chunks.
- [ ] Group by phase and step with expand, collapse, search, and deep links. (Step grouping, accessible expand/collapse, bounded search, and stable segment anchors exist; explicit runner-phase grouping remains.)
- [x] Sanitize ANSI output before HTML rendering.
- [x] Avoid loading complete logs into a LiveView process or browser DOM.
- [ ] Pass the 100 MB navigation criterion and accessibility checks.

## Phase 8 — MVP hardening and release

### OPS-101 — Complete observability and health

- **Depends on:** EXEC-103, GH-103, WEB-103
- [ ] Implement structured redaction-safe logs and correlation across webhook, pipeline, job, attempt, runner, and GitHub delivery.
- [x] Expose readiness/liveness and dependency health without leaking secrets.
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
