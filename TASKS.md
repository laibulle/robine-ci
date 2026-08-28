# Robine CI implementation plan

This file orders implementation work for the MVP and accepted post-MVP increments. Product behavior and architecture are defined in [docs/specs](docs/specs/README.md). A checkbox means the task and all of its exit criteria have been verified, not merely started.

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
- [x] Confirm the GitHub App permission set and GitHub Enterprise Server target. (GitHub.com only; repository permissions are Metadata read, Contents write for tag releases, Pull requests read, and Checks write; subscribed events are Push and Pull request.)

## Phase 1 — Repository and architecture foundation

### ARCH-004 — Expose the embeddable backend runtime

- **Spec:** [PLAT-003](docs/specs/platform/plat-003-embeddable-backend-runtime.md)
- **Depends on:** ARCH-003
- [x] Implement standalone and embedded supervision profiles without exporting UI.
- [x] Publish migration metadata and an isolated `robine_ci` storage prefix.
- [x] Enforce tenant isolation in every tenant-owned persistence adapter and constraint.
- [x] Add host-style integration tests proving embedded startup, authorization, and tenant isolation.
- [x] Verify standalone compatibility and the complete precommit suite.

### BOOT-001 — Bootstrap the Elixir/Phoenix project

- **Depends on:** DEC-001
- [x] Create the OTP application and Phoenix LiveView endpoint without generated business contexts.
- [x] Configure PostgreSQL, Tailwind, test environment, formatter, and deterministic local setup.
- [x] Add AGPL-3.0-or-later license and source headers policy if required.
- [x] Add `mix setup`, a full verification alias, and Docker Compose for application dependencies.
- [x] Keep Compose and Ecto development/test credentials aligned, authenticate PostgreSQL health checks, and document non-destructive stale-password recovery.
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
- [x] Reconcile committed queued jobs when their event-driven dispatch notification is lost or consumed early.
- [x] Publish state changes only after durable commit through idempotent outbox projections.

## Phase 3 — Local Docker execution

### EXEC-101 — Implement normalized execution specification

- **Specs:** [EXEC-001](docs/specs/execution/exec-001-local-docker-runner.md), [PLAT-002](docs/specs/platform/plat-002-clean-application-architecture.md)
- **Depends on:** WF-102, ARCH-002
- [x] Define a versioned, framework-free execution contract shared by server, runner, and CLI.
- [x] Provide authoritative, runner-neutral `ROBINE_BUILD_*` provenance for applications to embed and document reusable Elixir, JavaScript, and Go consumption patterns.
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
- [x] Support an attempt-scoped, allowlisted Docker-in-Docker service without exposing the runner host Docker socket.
- [x] Enforce global and repository concurrency and disk-pressure admission.
- [x] Give development self-hosted jobs a 16 GiB memory ceiling while retaining the 4 GiB production default.
- [x] Surface disk-pressure admission separately from runner-label placement and use environment-appropriate development/test thresholds.
- [x] Reconcile labeled orphan containers and volumes after restart.
- [x] Scope Docker ownership and orphan reconciliation by instance so colocated dev, test, and production runtimes cannot delete one another's resources.
- [x] Capture stopped-container exit state, including OOM status, in retained logs before cleanup.

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

### DATA-103 — Upload locally produced artifacts

- **Spec:** [DATA-003](docs/specs/storage/data-003-manual-artifact-uploads.md)
- **Depends on:** DATA-101, DATA-102, IAM-001
- [x] Persist explicit CI/manual artifact provenance without weakening attempt dependency rules.
- [x] Add shared manual upload, listing, and private download operations to the Storage facade.
- [x] Add a bounded authenticated raw-upload API with revocable local Bearer sessions.
- [x] Add a unified repository artifact LiveView for CI and manual provenance, with upload progress, retention, metadata, and downloads.
- [x] Verify authorization, limits, interruption cleanup, digest identity, retention, API, and UI behavior.

## Phase 5 — GitHub integration

### GH-101 — Implement GitHub App setup and credentials

- **Spec:** [GH-001](docs/specs/github/gh-001-github-integration.md)
- **Depends on:** DEC-004, SEC-101
- [x] Implement manifest-assisted setup or exact manual instructions.
- [x] Store private keys and webhook secrets as write-only encrypted instance credentials with environment bootstrap fallback.
- [x] Implement installation token lifecycle and live least-privilege permission diagnostics with exact corrective actions.
- [x] Expose integration health without leaking payload or credentials.
- [x] Replace the flat GitHub credential forms with the ordered GitHub App setup assistant defined by GH-001 UX-4 and UX-5.

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
- [x] Choose a target-specific packaging strategy and supported platforms. (GNU/Linux x86-64 escript plus target-native Exile runtime for the verified MVP binary.)
- [x] Implement version reporting, deterministic SHA-256 manifests, supported-host verification instructions, stable exit-code classes, and non-interactive output.
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

### IAM-103 — Add global permission-scoped artifact-upload tokens

- **Spec:** [IAM-002](docs/specs/identity/iam-002-scoped-api-tokens.md)
- **Depends on:** IAM-101, DATA-103
- [x] Persist opaque instance-global tokens as digests with bounded permissions and expiration.
- [x] Add authorized create, list, revoke, and resolve operations to the Identities facade.
- [x] Authenticate `artifacts:write` Bearer tokens without widening session or repository access.
- [x] Add an administrator-only global token-management LiveView with one-time secret reveal.
- [x] Verify multi-repository uploads, permission isolation, revocation, expiry, disabled owners, and session compatibility.

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
- [x] Upgrade pipeline history to the WEB-001 operational cockpit with URL-persisted filters, attention prioritization, compact responsive rows, source context, durations, and explicit refresh health.
- [x] Upgrade repository catalogue and detail to the WEB-001 operational experience with scoped activity, health/trust distinction, progressive connection, safe manual launch, and schedule context.
- [x] Embed Robine's own CI provenance and expose it through a discreet application footer and authenticated Build information page.
- [x] Unify product navigation and page hierarchy with active states, breadcrumbs, focused administration sections, responsive provenance access, normalized surfaces, and isolated destructive actions.
- [x] Give Robine a warmer, recognizable product character through brand-derived geometry, warmer theme tokens, restrained mineral accents, and human operational microcopy.
- [x] Redesign the desktop sidebar as a contextual Robine control column with stronger brand, active-navigation, provenance, and account hierarchy.

### WEB-103 — Implement scalable live logs

- **Spec:** [WEB-001](docs/specs/web/web-001-pipeline-experience.md)
- **Depends on:** WEB-102, SEC-102
- [x] Persist and request logs by sequence cursor.
- [x] Push newly persisted stdout/stderr segments to connected job views with polling fallback, and provide authorized retained combined/stdout/stderr file downloads.
- [x] Reconnect without duplicate or missing chunks.
- [x] Group persisted logs explicitly by runner phase and step with accessible expand/collapse, bounded search, and stable phase/step/segment deep links.
- [x] Sanitize ANSI output before HTML rendering.
- [x] Avoid loading complete logs into a LiveView process or browser DOM.
- [x] Stop terminal-job log polling and render the complete retained output in an independently streamed reader with stable scrolling.
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
  - External evidence gate: `mix robine.verify_acceptance --first-pipeline FILE --accessibility FILE --artifact-manifest SHA256SUMS`.

### DX-101 — Verify the ten-minute first pipeline

- **Spec:** [PROD-001](docs/specs/product/prod-001-mvp-definition.md)
- **Depends on:** QA-101, CLI-103, WEB-103
- [x] Test the documented target-specific release installation with real PostgreSQL, migrations, server readiness, Caddy validation, and complete cleanup on supported Linux.
- [ ] Reach a green GitHub check in under ten minutes, excluding approvals and image downloads.
  - Follow `docs/acceptance/first-pipeline.md` and retain a verified external evidence file.
- [x] Reproduce a representative failed CI job locally from the command shown in the UI.
- [ ] Conduct accessibility and first-use tests with developers unfamiliar with the implementation.
  - Follow `docs/acceptance/accessibility.md` and retain a verified external evidence file.
- [x] Fix or explicitly re-specify every material failure discovered.

### REL-101 — Prepare the first open-source release

- **Depends on:** DX-101
- [x] Confirm the complete AGPL-3.0-or-later text and a test-enforced locked third-party notice inventory.
- [x] Publish installation, upgrade, backup, recovery, security-model, and troubleshooting documentation.
- [x] Document supported versions, retention defaults, limitations, and trusted-repository assumptions.
- [x] Produce and verify checksummed server, CLI, and runner 0.1.0 artifacts, including exact license material and disabled Erlang Distribution in the server archive; all three real packaging smokes run in `mix qa`.
- [x] Publish a forward-migration and backup-restore rollback procedure.
- [ ] Tag the release only after all MVP acceptance criteria are verified.

### REL-102 — Publish GitHub tag releases

- **Spec:** [REL-002](docs/specs/releases/rel-002-github-tag-releases.md)
- **Depends on:** REL-101, DATA-102, GH-103
- [x] Normalize exact tag pushes and support distinct `push.tags` glob filters.
- [x] Add a tag-only workflow that retains server, CLI, and runner release outputs as three distinct `github-release` artifacts.
- [x] Publish the retained payload idempotently with the control-plane installation token.
- [x] Approve `Contents: write` on the live GitHub App and verify an annotated tag release with its retained 13.1 MB payload.
- [x] Resolve allowlisted runner OS and architecture variables in retained and GitHub release asset names.
- [x] Preserve a project-specific GitHub release asset prefix for repositories built by Robine CI.
- [x] Keep GitHub release asset filenames stable without duplicating the version carried by the tag.

## Phase 9 — Remote runners

### RUN-201 — Implement runner enrollment and identity

- **Spec:** [RUN-001](docs/specs/runners/run-001-remote-runner-protocol.md)
- **Depends on:** ARCH-003, IAM-101
- [x] Implement the accepted enrollment, authentication, rotation, and revocation slice.
- [x] Add runner, enrollment-token, and credential persistence with no plaintext secret retention.
- [x] Expose administrator-authorized token creation and public single-use enrollment through facade use cases.
- [x] Implement constant-time credential authentication, five-minute-overlap rotation, and immediate revocation.
- [x] Audit every enrollment, rotation, authentication anomaly, and revocation without secret material.
- [x] Prove expiry, replay prevention, race safety, rate limits, and architecture boundaries.

### RUN-202 — Implement the versioned runner session protocol

- **Spec:** [RUN-001](docs/specs/runners/run-001-remote-runner-protocol.md)
- **Depends on:** RUN-201
- [x] Owner: Codex — versioned remote-runner protocol implemented and verified.
- [x] Add a Phoenix WebSocket server adapter with header-based authentication and explicit version negotiation.
- [x] Package and checksum the standalone runner with a TLS-validating outbound WebSocket client and release smoke.
- [x] Implement bounded hello capabilities, heartbeat persistence, and immediate disconnect-on-revocation behavior.
- [x] Implement capped full-jitter reconnect backoff and active-attempt reconciliation.
- [x] Derive runner staleness after 60 seconds and expose it to scheduling and administration.
- [x] Implement runner-owned durable message IDs, attempt sequences, acknowledgements, and duplicate/reorder handling in one transaction.
- [x] Transfer attempt-scoped source, logs, artifacts, caches, and secrets with bounded backpressure.
- [x] Prove restart, disconnect, revocation, proxy, and version-skew behavior end to end.

### RUN-203 — Implement fleet matching and administration

- **Spec:** [RUN-002](docs/specs/runners/run-002-runner-fleet-and-scheduling.md)
- **Depends on:** RUN-202
- [x] Extend workflow v1 with validated all-match `runs-on` labels and a Docker default.
- [x] Separate administrator labels from bounded runner-reported capabilities.
- [x] Atomically match and reserve compatible capacity with repository fairness.
- [x] Implement enabled, draining, and revoked administration with audited LiveView controls, including immediate cancellation delivery to connected revoked runners.
- [x] Explain absent, offline, draining, and busy matching capacity on queued jobs.
- [x] Verify concurrency safety, fairness, accessibility, and 1,000-runner scheduling performance.

### RUN-204 — Implement provider-neutral autoscaling

- **Spec:** [RUN-002](docs/specs/runners/run-002-runner-fleet-and-scheduling.md)
- **Depends on:** RUN-203
- [x] Define autoscaling policy, desired-capacity, provider, and durable intent ports.
- [x] Reconcile provision and termination effects with stable idempotency keys.
- [x] Protect active leases and enforce min/max, idle, and cooldown boundaries.
- [x] Expose desired versus observed capacity and degraded provider health.
- [x] Prove restart-safe behavior with a fake provider adapter before accepting a cloud adapter spec.

## Post-MVP backlog

### RUN-301 — Deliver a native macOS runner

- **Spec:** [RUN-003](docs/specs/runners/run-003-macos-native-runner.md)
- **Depends on:** RUN-203
- [x] Owner: Codex — native execution and launchd operation verified end to end on Apple Silicon macOS.
- [x] Add a dedicated host executor with attempt-isolated workspaces and shared step semantics.
- [x] Normalize Darwin/Apple Silicon capabilities and keep default Docker jobs off native runners.
- [x] Preserve bounded redacted logs, timeout, cancellation, conditional execution, and cleanup.
- [x] Publish and restore cache and artifact archives through attempt-scoped transfers.
- [x] Verify a TLS-connected pipeline on target Mac hardware.
- [x] Document and verify launchd installation, upgrades, troubleshooting, and removal.

### RUN-302 — Replace the macOS runner runtime with Go

- **Spec:** [RUN-003](docs/specs/runners/run-003-macos-native-runner.md)
- **Depends on:** RUN-301
- [ ] Owner: Codex — self-contained Go runner implemented and verified end to end on Apple Silicon macOS.
- [x] Implement protocol-v1 enrollment, Phoenix Channel reconnect/reconciliation, heartbeat, cancellation, and ordered acknowledgements in pure Go.
- [x] Execute native steps in isolated workspaces with bounded redacted logs, conditions, timeout, process-group cancellation, and cleanup.
- [x] Safely transfer source, secrets, caches, and artifact archives through the existing attempt-scoped API.
- [x] Cross-compile and checksum Darwin, Linux, and Windows `arm64` and `amd64` releases from Linux with `CGO_ENABLED=0`.
- [ ] Build a macOS `.app` fixture and prove that its declared artifact is retained and downloadable from Robine CI.
- [x] Update launchd and operator documentation for the self-contained executable.

These items are intentionally unordered and must receive specifications before implementation:

- [x] S3-compatible artifact and cache storage — DATA-002 shipped with MinIO and remote-runner evidence.
  - [x] Specify content keys, bounded spooling, multipart abort, credentials, encryption, health, and failure semantics.
  - [x] Remove concrete local-storage dependencies from retention, health, and runtime composition.
  - [x] Implement validated local/S3 runtime selection and a digest-verifying S3 adapter.
  - [x] Pass a real multipart put/get/inventory/delete smoke against pinned MinIO.
  - [x] Prove interrupted multipart abort, bounded memory, 1,000-object pagination, and normalized failure classes.
  - [x] Add durable backend migration acknowledgement with an exact transition token and operator runbook.
  - [x] Prove an S3-backed two-job remote-runner cache/artifact journey without bucket credentials.
- [x] GitLab and Forgejo source-control providers — SCM-001 shipped with pinned real-provider adapter contracts; additional providers remain future work.
- [x] Service containers — EXEC-002 shipped with PostgreSQL, Redis, CLI, remote-runner, and cleanup evidence.
- [x] Conditional execution — WF-002 shipped with fixed job/step conditions and local/remote parity.
- [x] Matrices — WF-003 shipped with bounded expansion and CI/CLI/remote parity.
- [x] Manual workflow inputs — WF-004 shipped and verified in Phase 13.
- [x] Reusable workflows and scheduled triggers — WF-005 and WF-006 shipped.
- [ ] Micro-VM isolation for untrusted workloads.
- [ ] Managed Robine cloud and commercial support operations.
- [ ] SAML, LDAP, SCIM, and identity group mapping.
- [ ] Deployment environments and approvals — specified by DEP-001; implementation tracked in Phase 18.
- [ ] Public release assets independent from repository visibility — specified by REL-003; implementation tracked in Phase 19.

## Phase 18 — Native deployments

### DEP-101 — Establish deployment domain and persistence

- **Spec:** [DEP-001](docs/specs/deployments/dep-001-native-deployments.md)
- **Depends on:** IAM-102, RUN-203, SCM-802, WEB-103
- [x] Add pure environment, service specification, artifact snapshot, deployment, and transition-policy modules with name, path, protection, digest, volume, and state invariants.
- [x] Persist environment configuration, immutable artifact and desired-state snapshots, approval, ordered idempotent phase events, audit correlation, and terminal outcomes behind tenant RLS policies.
- [x] Expose administrator-authorized configuration and deployment operations through the `Robine.Deployments` facade.
- [ ] Prove transition, authorization, self-approval, concurrency, and restart-safety behavior. Transition, runner ownership, idempotent replay, self-approval, and serialized queue coverage exist; control-plane/runner restart recovery remains.

### DEP-102 — Execute native Docker deployments safely

- **Spec:** [DEP-001](docs/specs/deployments/dep-001-native-deployments.md)
- **Depends on:** DEP-101
- [x] Resolve and pin the application artifact, source revision, persistent-service specs, and normalized desired-state digests before approval.
- [x] Add a deployment-capable runner offer and a locally root-allowlisted Docker convergence executor without arbitrary shell or Compose input.
- [ ] Transfer only referenced secrets and the exact digest-verified artifact, reuse cursor-based redacted logs, and guarantee attempt cleanup without deleting persistent volumes. Secret/artifact transfer, safe temporary cleanup, and volume preservation exist; deployment log streaming remains.
- [ ] Serialize deployments per environment and integrate ordered events, cancellation, lease recovery, remote observation, and capacity explanations. Queue serialization and ordered runner events exist; remote cancellation, lease recovery, observation, and diagnostics remain.
- [x] Verify successful activation through bounded same-origin Req health and exact-version checks.
- [ ] Require fresh backup evidence for PostgreSQL major upgrades and reject automatic downgrade or unsafe application rollback.

### DEP-103 — Deliver the deployment experience

- **Spec:** [DEP-001](docs/specs/deployments/dep-001-native-deployments.md)
- **Depends on:** DEP-102, OPS-101
- [x] Add accessible application/platform environment configuration and overview to repository administration.
- [ ] Add deployment request, separate production approval, timeline, grouped live logs, cancellation, redeploy, and retry-verification journeys. Request, independent approval, status timeline, pre-effect cancellation, and retry verification exist; logs, explicit redeploy, rollback, and remote cancellation remain.
- [ ] Emit bounded metrics, structured correlation events, audit events, and deployment readiness diagnostics.
- [ ] Verify staging and protected-production journeys end to end with real PostgreSQL, S3-compatible storage, application, ingress, persistent volumes, and a deployment runner restart.

## Phase 19 — Public artifact publication

### REL-301 — Establish publication policy and domain

- **Spec:** [REL-003](docs/specs/releases/rel-003-public-artifact-publication.md)
- **Depends on:** IAM-102, WEB-103, DATA-102
- [ ] Add pure publication, repository-policy, public-name, and transition modules.
- [ ] Persist repository opt-in, opaque public slug, immutable publication identity, provenance, state, and audit correlation with tenant isolation.
- [ ] Expose administrator policy and publication operations through the `Robine.Publications` facade.
- [ ] Prove default privacy, authorization, immutable conflict, withdrawal, quota, and transition behavior.
  - Partial: repository policy, public slug validation, publication read projection, audit, tenant isolation, and administrator/viewer boundaries are implemented; publication transitions, conflicts, withdrawal, and quotas remain.

### REL-302 — Stage and deliver public objects

- **Spec:** [REL-003](docs/specs/releases/rel-003-public-artifact-publication.md)
- **Depends on:** REL-301
- [ ] Extend workflow v1 with a validated `publications/stage` built-in restricted to authenticated semantic-version tag runs.
- [ ] Reuse attempt-scoped private transfer and create durable publication intents without exposing non-terminal content.
- [ ] Add independently configured local and S3-compatible public object adapters with deterministic digest-safe keys.
- [ ] Publish only after successful terminal projection with idempotent retry, verification, and conflict handling.
- [ ] Pass the public-store contract against a pinned Garage fixture, including multipart interruption and withdrawal.

### REL-303 — Deliver public downloads and repository UX

- **Spec:** [REL-003](docs/specs/releases/rel-003-public-artifact-publication.md)
- **Depends on:** REL-302, OPS-101
- [ ] Add bounded proxy download and optional validated direct-delivery URLs with immutable, range, checksum, MIME, disposition, and nosniff behavior.
- [x] Add the non-cached stable `latest` filename alias without weakening immutable release URLs.
- [ ] Add repository publication settings, release history, provenance, copyable URLs, retry, and withdrawal journeys.
  - Partial: repository settings, release history, provenance, policy state, and download actions are implemented; copy interaction, retry, and withdrawal remain.
- [ ] Add a public metadata page isolated from authenticated repository navigation and private identity.
- [ ] Emit bounded metrics and correlated audit events and verify a private-repository-to-public-Garage journey end to end.

## Phase 10 — Service containers

### EXEC-301 — Extend workflow and execution contracts

- **Spec:** [EXEC-002](docs/specs/execution/exec-002-service-containers.md)
- **Depends on:** EXEC-103, RUN-202
- [x] Add source-located workflow validation and normalization for bounded service definitions.
- [x] Add the inspect-safe service execution contract and server/CLI mapping.
- [x] Prove invalid fixtures and secret mapping rules without Docker.

### EXEC-302 — Implement Docker service lifecycle

- **Spec:** [EXEC-002](docs/specs/execution/exec-002-service-containers.md)
- **Depends on:** EXEC-301
- [x] Create attempt-owned networks and hardened service containers without host publication or workspace mounts.
- [x] Implement bounded TCP readiness, early-exit detection, redacted diagnostics, cancellation, and cleanup.
- [x] Extend label-safe orphan reconciliation to service containers, anonymous volumes, and networks.

### EXEC-303 — Verify local and remote service journeys

- **Spec:** [EXEC-002](docs/specs/execution/exec-002-service-containers.md)
- **Depends on:** EXEC-302
- [x] Run PostgreSQL and Redis fixtures through the CLI and a remote runner.
- [x] Prove secret non-persistence, resource isolation, failure diagnostics, and interrupted cleanup.
- [x] Complete EXEC-002 acceptance evidence and full QA.

## Phase 11 — Conditional execution

### WF-301 — Extend condition contracts

- **Spec:** [WF-002](docs/specs/workflows/wf-002-conditional-execution.md)
- **Depends on:** WF-102, PIPE-102, EXEC-301
- [x] Add source-located validation and normalized job/step condition enums.
- [x] Persist conditions without adding an expression evaluator or provider data.
- [x] Add invalid fixtures and pure condition-policy tests.

### WF-302 — Implement conditional job scheduling

- **Spec:** [WF-002](docs/specs/workflows/wf-002-conditional-execution.md)
- **Depends on:** WF-301
- [x] Atomically queue or skip jobs from terminal dependency snapshots.
- [x] Ensure skipped jobs create no attempts and project distinctly.
- [x] Prove concurrent release and reconciliation idempotency.

### WF-303 — Implement conditional step execution

- **Spec:** [WF-002](docs/specs/workflows/wf-002-conditional-execution.md)
- **Depends on:** WF-301, WF-302
- [x] Continue ordinary failures into matching failure/always steps while retaining the first failure.
- [x] Halt all remaining conditions on cancellation, timeout, service loss, or adapter failure.
- [x] Verify CLI and remote parity, UX, architecture, and full QA (290 tests).

## Phase 12 — Job matrices

### WF-401 — Extend and expand workflow contracts

- **Spec:** [WF-003](docs/specs/workflows/wf-003-job-matrices.md)
- **Depends on:** WF-102, WF-301
- [x] Validate bounded matrix strategies, axes, values, image tokens, and environment collisions.
- [x] Expand deterministic job variants and fan-in dependencies before pipeline creation.
- [x] Enforce expanded job/step limits and ambiguous artifact rules with source-located diagnostics.

### WF-402 — Persist and schedule matrix variants

- **Spec:** [WF-003](docs/specs/workflows/wf-003-job-matrices.md)
- **Depends on:** WF-401, PIPE-102
- [x] Persist immutable base IDs and matrix values in workflow revisions and job execution metadata.
- [x] Schedule, conditionally release, retry, and project every variant as an ordinary job.
- [x] Prove independent and simultaneous variant reconciliation without duplicate attempts.

### WF-403 — Deliver matrix DX and parity

- **Spec:** [WF-003](docs/specs/workflows/wf-003-job-matrices.md)
- **Depends on:** WF-402, CLI-103, GH-103, WEB-102, RUN-202
- [x] Support CLI selection by base group and exact generated key with matching execution contracts.
- [x] Expose matrix values consistently in LiveView, logs, and GitHub checks.
- [x] Verify services, remote runners, architecture, release smoke, and full QA (305 tests).

## Phase 13 — Manual workflow inputs

### WF-501 — Extend workflow dispatch contracts

- **Spec:** [WF-004](docs/specs/workflows/wf-004-manual-workflow-inputs.md)
- **Depends on:** WF-102, WF-401
- [x] Normalize typed bounded input definitions and exact source diagnostics.
- [x] Implement the pure submitted-input policy and reserved environment collision rules.
- [x] Inject immutable values into ordinary and matrix job contracts.

### WF-502 — Resolve and launch exact revisions

- **Spec:** [WF-004](docs/specs/workflows/wf-004-manual-workflow-inputs.md)
- **Depends on:** WF-501, GH-102, PIPE-101
- [x] Resolve the GitHub default-branch head and fetch workflows only at the exact SHA.
- [x] Resolve a maintainer-selected branch server-side and re-resolve its exact SHA at manual launch.
- [x] Expose authorized discovery and idempotent manual-launch use cases through the repository facade.
- [x] Persist trigger, actor, SHA, workflow revision, input map, jobs, and outbox atomically.

### WF-503 — Deliver manual-run DX and parity

- **Spec:** [WF-004](docs/specs/workflows/wf-004-manual-workflow-inputs.md)
- **Depends on:** WF-502, CLI-103, WEB-102, RUN-202
- [x] Build the accessible repository launch flow and input-aware pipeline/job views.
- [x] Add repeated CLI `--input` validation and exact reproduction commands.
- [x] Verify matrices, remote runners, authorization, idempotency, architecture, and full QA (313 tests).

## Phase 14 — Scheduled workflows

### WF-601 — Extend schedule contracts

- **Spec:** [WF-005](docs/specs/workflows/wf-005-scheduled-workflows.md)
- **Depends on:** WF-102, WF-401
- [x] Implement a pure bounded five-field UTC cron value object.
- [x] Normalize bounded schedule declarations with exact source diagnostics and shared fixtures.
- [x] Prove matching semantics independently of Oban and system time.

### WF-602 — Reconcile durable occurrences

- **Spec:** [WF-005](docs/specs/workflows/wf-005-scheduled-workflows.md)
- **Depends on:** WF-601, GH-102, PIPE-101
- [x] Persist the intended occurrence on pipelines and a compare-and-set scheduler cursor.
- [x] Reconcile bounded missed minutes against one exact GitHub head fetch per repository.
- [x] Create idempotent scheduled pipelines and advance the cursor only after a complete scan.

### WF-603 — Deliver schedule operations and DX

- **Spec:** [WF-005](docs/specs/workflows/wf-005-scheduled-workflows.md)
- **Depends on:** WF-602, GH-103, WEB-102, OPS-101
- [x] Run reconciliation every minute through a background adapter.
- [x] Expose schedules, intended occurrences, checks, metrics, audit, and scheduler health.
- [x] Verify recovery, concurrency, architecture, release smoke, and full QA (326 tests).

## Phase 15 — Reusable workflows

### WF-701 — Resolve exact multi-file workflow contracts

- **Spec:** [WF-006](docs/specs/workflows/wf-006-reusable-workflows.md)
- **Depends on:** WF-102, WF-501
- [x] Validate bounded include declarations and reusable `workflow_call` inputs.
- [x] Implement pure recursive resolution, cycle/depth/count limits, namespaces, and input injection.
- [x] Run the ordinary validator over one deterministic composed raw graph with source diagnostics.

### WF-702 — Persist and execute composed revisions

- **Spec:** [WF-006](docs/specs/workflows/wf-006-reusable-workflows.md)
- **Depends on:** WF-701, GH-102, PIPE-101
- [x] Resolve push, pull-request, manual, and schedule entries from one exact fetched source set.
- [x] Persist every included source and digest in the immutable workflow revision.
- [x] Execute composed jobs identically through local and remote runners.

### WF-703 — Deliver reusable-workflow DX and parity

- **Spec:** [WF-006](docs/specs/workflows/wf-006-reusable-workflows.md)
- **Depends on:** WF-702, CLI-103, GH-103, WEB-102
- [x] Discover local sources for CLI validation/execution and retain stable namespaced selection.
- [x] Display included revisions/digests and composed names consistently in LiveView and checks.
- [x] Verify recursion failures, input isolation, idempotency, architecture, release smoke, and full QA (335 tests).

## Phase 16 — GitLab and Forgejo source control

### SCM-801 — Establish provider-neutral repository contracts

- **Spec:** [SCM-001](docs/specs/source-control/scm-001-gitlab-forgejo-integration.md)
- **Depends on:** ARCH-002, GH-102, GH-103
- [x] Replace GitHub-specific shared use-case dependencies with a provider-neutral source-control port and runtime registry.
- [x] Persist provider kind and configured-instance identity with collision-safe repository, delivery, and projection constraints.
- [x] Preserve every existing GitHub journey and migrate existing rows to the default GitHub instance.

### SCM-802 — Implement GitLab delivery and status parity

- **Spec:** [SCM-001](docs/specs/source-control/scm-001-gitlab-forgejo-integration.md)
- **Depends on:** SCM-801
- [x] Validate GitLab webhook tokens before parsing and normalize push/merge-request events.
- [x] Fetch workflows, source, default head, paginated discovery, and permissions through bounded exact-SHA GitLab APIs.
- [x] Project pipeline/job state through durable idempotent GitLab commit statuses.

### SCM-803 — Implement Forgejo delivery and status parity

- **Spec:** [SCM-001](docs/specs/source-control/scm-001-gitlab-forgejo-integration.md)
- **Depends on:** SCM-801
- [x] Validate Forgejo webhook signatures before parsing and normalize push/pull-request events.
- [x] Fetch workflows, source, default head, paginated discovery, and permissions through bounded exact-SHA Forgejo APIs.
- [x] Project pipeline/job state through durable idempotent Forgejo commit statuses.

### SCM-804 — Deliver multi-provider operations and QA

- **Spec:** [SCM-001](docs/specs/source-control/scm-001-gitlab-forgejo-integration.md)
- **Depends on:** SCM-802, SCM-803, WEB-102, OPS-101
- [x] Add provider-aware setup, discovery, repository health, webhook routes, and corrective guidance.
- [x] Prove identity separation, redirect/size bounds, outage reconciliation, manual/schedule/reusable/local/remote parity, and migrations.
- [x] Run architecture checks, security audits, pinned Forgejo 16.0.2 and GitLab CE 19.2.1 integration smokes, server/CLI/runner release smokes, and full QA (355 tests; heavyweight GitLab smoke verified separately).

## Phase 17 — Coverage reporting

### QUAL-101 — Establish the local coverage contract

- **Spec:** [QUAL-001](docs/specs/quality/qual-001-coverage-reporting.md)
- **Depends on:** BOOT-001
- [x] Add a test-only coverage reporter and one `mix coverage` command that prepares the database.
- [x] Enforce a 75% global threshold and generate an ignored HTML report.
- [x] Document the local workflow and verify it against the complete suite.

### QUAL-102 — Publish coverage through Robine CI

- **Spec:** [QUAL-001](docs/specs/quality/qual-001-coverage-reporting.md)
- **Depends on:** QUAL-101, DATA-001, GH-103
- [x] Emit a bounded machine-readable coverage marker and retain the HTML report as an artifact.
- [x] Add the total, threshold, outcome, and report name to pipeline and job provider-check summaries.
- [x] Verify successful, malformed/missing marker, pagination, retry, and authorization journeys, including a live GitHub publication with `Checks: write`.
- [x] Expose authenticated report downloads from provider checks and a stable public repository coverage badge.
- [x] Expose a stable public build badge backed by the newest repository pipeline status.

## Phase 18 — Source-control scope

### SCM-901 — Restrict the MVP product surface to GitHub

- **Spec:** [SCM-002](docs/specs/source-control/scm-002-github-only-product-surface.md)
- **Depends on:** GH-102, SCM-801
- [x] Remove deferred-provider controls, labels, credentials, health cards, LiveView events, and webhook routes from the product surface.
- [x] Keep provider-neutral persistence and dormant adapters intact for a future explicit reactivation decision.
- [x] Verify the GitHub-only UI and unavailable webhook paths with focused tests and full precommit QA (396 tests passed; 6 integration tests skipped).
