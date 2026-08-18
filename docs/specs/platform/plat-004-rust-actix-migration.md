# PLAT-004 — Rust and Actix migration

## Status

- **State:** Implementing
- **Owner:** Robine maintainers
- **Target:** Post-MVP
- **Last updated:** 2026-08-18

## Summary

Robine will replace its Elixir/Phoenix implementation with a Rust control plane built on Actix Web while preserving the accepted product contracts, PostgreSQL data, runner protocol, and externally observable behavior.

## Problem

The shipped application is implemented across hundreds of Elixir modules and relies on OTP, Phoenix, LiveView, Ecto, and Oban. Replacing the runtime without a compatibility boundary risks data loss, authorization regressions, duplicate execution, and silent changes to public HTTP and runner behavior.

## Goals

- Preserve every accepted product specification unless it is explicitly amended.
- Preserve PostgreSQL data and provide forward-only migrations for schema changes.
- Replace the server, worker, CLI, runner, and browser delivery with Rust implementations.
- Keep framework-independent domain rules isolated from Actix, SQL, Docker, and HTTP.
- Permit behavior-by-behavior verification before the Elixir implementation is removed.

## Non-goals

- Running Elixir and Rust indefinitely as two production control planes.
- Reinterpreting the migration as permission to weaken security, tenant isolation, or durability.
- Maintaining the Elixir embedding API after the Rust replacement is declared complete.

## Users and use cases

### Primary user

An operator upgrading an existing Robine deployment without losing pipelines, credentials, artifacts, or runner connectivity.

### Use cases

1. Start the Rust server against a migrated or existing Robine PostgreSQL database.
2. Exercise the same browser, webhook, badge, health, metrics, and runner routes.
3. Run existing workflows with equivalent scheduling, execution, storage, and source-control behavior.
4. Roll back to the Elixir release before final cutover when a compatibility gate fails.

## Requirements

### Functional requirements

- **FR-1:** The Rust workspace MUST separate framework-independent domain/application code from Actix delivery and infrastructure adapters.
- **FR-2:** Existing HTTP paths, methods, authentication rules, status codes, payloads, and runner protocol versions MUST remain compatible unless another accepted specification changes them.
- **FR-3:** Existing PostgreSQL records MUST remain readable; migration tooling MUST be forward-only and safe under deployment restart.
- **FR-4:** Durable work MUST retain at-least-once processing, bounded retries, idempotency, reconciliation, and outbox semantics.
- **FR-5:** Every tenant-owned query and mutation MUST derive its tenant from the execution context.
- **FR-6:** The Rust server MUST expose `/health/live` and `/health/ready` from the first executable increment.
- **FR-7:** The Elixir implementation MUST be removed only after all migration parity gates pass.

### UX requirements

- **UX-1:** Browser workflows MUST retain equivalent information architecture, accessibility, responsive behavior, and real-time updates.
- **UX-2:** Upgrade and rollback MUST not require users to recreate accounts or reconnect repositories.

### Operational requirements

- **OR-1:** The control plane MUST shut down gracefully without accepting new dispatch work after shutdown begins.
- **OR-2:** Rust tests, formatting, linting, dependency auditing, and migration compatibility checks MUST run in CI.
- **OR-3:** A single deployment MUST have only one active scheduler owner during staged cutover.

## Proposed design

The repository temporarily contains both implementations. A Cargo workspace under `rust/` contains a framework-free `robine-core` crate and delivery/adapters in separate crates. Context facades become Rust application services whose dependencies are traits. Actix handlers call only those services. PostgreSQL adapters own SQL and transactions; an SQL-backed job/outbox subsystem replaces Oban.

Migration proceeds in vertical slices: foundation and compatibility inventory; database and identity; workflows and pipelines; workers and source control; runners, storage, and execution; browser UI and real-time transport; CLI/releases; final cutover and Elixir removal. Each slice gains parity tests against the accepted specification before ownership switches.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Rust process fails before cutover | Elixir remains authoritative | Restart Rust or disable the shadow deployment |
| Schema incompatibility | Readiness fails before serving traffic | Restore the previous release and correct the forward migration |
| Duplicate durable delivery | Idempotency constraints suppress the duplicate | Reconcile from committed database state |
| Parity test fails | The affected slice cannot become authoritative | Fix the Rust slice while Elixir remains active |

## Security and privacy

Cryptographic formats, write-only secret behavior, webhook verification, runner credential scope, CSRF/session protections, and audit semantics remain contract requirements. Secrets must never enter Rust debug output, tracing fields, panic messages, or client-visible errors.

The Actix source-control boundary now enforces the accepted one-mebibyte body limit and bounded provider headers, verifies GitHub and Forgejo HMACs plus GitLab tokens in constant time over the raw body before JSON decoding, and records provider-namespaced delivery identities through tenant-scoped SQL deduplication. Provider event normalization and durable processing remain migration work and therefore this slice is not yet authoritative.

## Observability

The Rust runtime publishes compatible health and Prometheus endpoints, structured correlation IDs, queue/dispatch/storage metrics, and audit events. During staged migration, parity mismatches are counted without logging sensitive payloads.

## Acceptance criteria

- [x] A Cargo workspace builds with a framework-free core crate and an Actix server crate.
- [x] The Actix server implements tested liveness and readiness routes at the existing paths.
- [x] Rust execution-context validation rejects missing tenants and capabilities.
- [x] SQLx connects to the existing migrated PostgreSQL schema and scopes reads through the existing row-level-security tenant setting.
- [x] Rust resolves existing SHA-256 opaque session digests and serves an authenticated pipeline-list API through the application boundary.
- [x] Rust verifies existing Argon2 local credentials and creates, resolves, and revokes compatible seven-day opaque sessions.
- [x] Rust implements the expiring out-of-band first-administrator bootstrap with constant-time token verification and transactional one-user enforcement.
- [x] Rust exposes administrator-only identity queries and transactional role changes that preserve the final usable administrator.
- [x] Rust starts OIDC authorization with server-owned one-use state, nonce, and S256 PKCE, validates signed callback claims, provisions only by stable issuer/subject identity, and rejects verified-email collisions.
- [x] Rust exposes maintainer-authorized pipeline cancellation and atomically updates tenant-scoped pipeline/job state with a compatible durable projection outbox event.
- [x] Rust exposes maintainer-authorized narrow job retry, refuses invalid lifecycle, unsuccessful dependency, and unavailable retained-artifact inputs, and atomically reopens accepted work with a dispatching projection outbox event.
- [x] Rust exposes tenant-scoped maintainer-authorized pipeline queueing with idempotent created/queued/running behavior and terminal-state refusal.
- [x] Rust validates and atomically creates pipeline metadata, immutable workflow revisions and included-source digests, normalized dependency jobs, and one compatible `pipeline.created` outbox event, with conflict-safe idempotent reuse and rollback coverage.
- [x] Rust owns framework-independent schema-v1 YAML parsing for the shared workflow fixture corpus, returns stable source-located diagnostics through Actix, validates canonical workflow paths, selected triggers, typed/defaulted inputs, artifact dependencies, and operator-configured limits, expands deterministic matrix jobs and fan-in dependencies, and derives the durable pipeline graph from the immutable revision source.
- [x] Rust purely composes bounded same-revision reusable workflows before validation, namespaces nested jobs and internal artifact/dependency edges, isolates normalized direct call inputs, rejects missing sources, cycles, excessive depth/count, external dependencies, and generated-ID overflow, and retains only reachable included sources and digests in the immutable revision.
- [x] Rust atomically claims local queued work with global/per-repository capacity, oldest-pipeline fairness, trusted-repository filtering, concurrent oversubscription protection, leased idempotent attempts, pipeline/job transitions, and a compatible projection event.
- [x] Rust atomically records ordered idempotent local attempt events, validates result reasons, reconciles terminal jobs, propagates success/failure/always dependency conditions to stability, derives terminal pipeline state, and appends compatible dispatching projection events.
- [x] Rust monotonically renews active local attempt leases without advancing event sequences and atomically reconciles tenant-scoped expired attempts as one ordered `failed/runner_lost` outcome, including exactly-once, terminal-state, and cross-tenant coverage.
- [x] Rust authenticates existing remote-runner HMAC credentials from `SECRET_KEY_BASE`, rejects missing, invalid, expired, or revoked machine identity, renews only that runner's active leases in one tenant transaction, records runner presence, and returns pipeline cancellation requests.
- [x] Rust authenticates bounded remote-runner reconnect reports, locks and reads only active attempts durably assigned to that runner, returns acknowledged sequences for resumable work, and deterministically reports stale client attempts as lease-lost without creating duplicate attempts.
- [x] Rust authenticates remote attempt events, requires durable runner ownership, enforces positive ordered sequences and result reasons, persists unique runner/message receipts in the same transaction as state and graph reconciliation, accepts exact replay, and rejects conflicting message reuse, stale delivery, gaps, and cross-runner mutation.
- [x] Rust places jobs on remote runners only while enabled, protocol-compatible, fresh, executable, below declared concurrency, and label-compatible; persists attempt ownership under the scheduler lock; and returns a provenance-rich normalized execution offer only to the authenticated owning runner.
- [x] Rust exposes pending remote offers through authenticated heartbeat polling without renewing unaccepted reservations, enforces the durable acceptance deadline, records explicit idempotent accept/reject outcomes, and scopes source, selected-secret, log, cache, and artifact transfers to the owning attempt with bounded archive validation and digest verification.
- [ ] Rust accepts authenticated bounded Actix WebSocket upgrades on the compatible Phoenix transport path, negotiates protocol v1 through hello/welcome, persists bounded software and capability metadata, reconciles reported attempts, emits heartbeat acknowledgements, pending offers, and cancellations, and durably processes accept/reject, ordered attempt, and log events with compatible acknowledgements and conflict diagnostics. End-to-end reverse-proxy parity remains before this criterion is complete.
- [x] Rust provides administrator-only short-lived enrollment-token creation, atomic one-time runner enrollment, compatible HMAC digest-only credential storage, bounded-overlap rotation, immediate runner/all-credential revocation, secret-free audit records, and no-store Actix responses that expose each generated secret only once.
- [x] Rust exposes an administrator-only tenant-scoped runner fleet projection with durable enabled/draining/revoked state, online/stale/busy/offline connectivity, bounded capabilities and labels, active work, concurrency and available capacity; locked configuration updates validate names/labels/state and append before/after audit metadata.
- [x] Actix bounds enrollment attempts per source and WebSocket authentication attempts per source/runner over a one-minute window, returns `429` with `Retry-After`, clears successful keys, prunes expired cardinality, and persists authentication-failure audits containing only a claimed-ID-valid flag and correlation identifier—never credentials or tokens.
- [x] Actix delivers a responsive semantic runner-fleet browser with cookie-or-bearer session resolution, `HttpOnly` `SameSite=Lax` session cookies, constant-time derived CSRF verification, no-store one-time enrollment/rotation results, accessible capacity/connectivity status, and progressively enhanced configuration, drain/enable, rotation, and revocation forms.
- [x] Rust owns SQL outbox polling with concurrent `SKIP LOCKED` claims, idempotent pipeline-created/projection handling, atomic unique durable dispatch-job insertion, stable capped exponential retry, ten-attempt dead-lettering, tenant isolation, and a shutdown-aware runtime loop.
- [x] Rust concurrently claims durable dispatch jobs, atomically creates a leased local attempt and its unique execution handoff before completing dispatch, retries bounded failures, reclaims stale claims, and reconciles active local attempts whose execution handoff is missing.
- [x] Rust owns a framework-independent execution contract and Docker adapter with attempt-scoped labeled containers, volumes, and private service networks; image acquisition; resource ceilings; dropped capabilities; `no-new-privileges`; sequential same-workspace steps; condition handling; bounded job timeout; cleanup; and instance-scoped orphan selection. Service containers receive no workspace, socket, host port, or unrelated environment; readiness runs from the digest-pinned hardened helper; active liveness failure stops the job; and the narrow official DinD exception remains explicit. Preparation and liveness failures retain at most 64 KiB, redact all resolved execution and service secrets before durable system-stream persistence, name the failed service and phase, preserve `service_unavailable`, and detect early exit without waiting for the readiness deadline. A dedicated runtime worker claims unique execution handoffs, reconstructs authoritative specifications, advances ordered attempt state outside effect transactions, persists independently observed stdout/stderr in bounded tenant-scoped idempotent chunks, polls durable cancellation during commands, stops the full container, completes terminal durable work, and recovers both execution and log cursors after crashes. Exact-SHA checkout resolves only tenant-owned trusted repositories, uses provider-authenticated bounded archives, rejects unsafe archive entries and expansion, and materializes files into an ephemeral attempt workspace before user commands. Cache restore/save and artifact upload/download execute in declared order, validate archives under internal size/count/ratio/time deadlines, reject special entries and pre-existing destination symlinks, verify content-addressed local or S3-compatible blobs on read, enforce tenant/repository quotas transactionally, and resolve artifacts only from declared successful dependencies. S3 mode uses the standard workload-identity credential chain, validated HTTPS or explicitly loopback HTTP endpoints, optional path-style addressing and server-side encryption, bounded multipart publication with abort, post-publication metadata verification, paginated inventory, and exact migration acknowledgement when retained metadata changes namespace. Hourly retention removes bounded expired metadata and logs, durably delays possible garbage, rechecks references before deletion, reconciles only complete backend inventories, reports missing/unsafe objects, stages bounded physical orphans, and deletes abandoned temporary files.
- [x] Rust resolves only explicitly declared tenant-scoped repository or allowlisted instance secrets, requires every declaration to resolve exactly once, decrypts the existing versioned AES-256-GCM format using byte-identical Erlang external-term AAD, rejects tampering and unavailable keys, keeps plaintext in zeroizing execution values, injects job and mapped service environments without command-line values, and masks matches independently across stdout/stderr chunk boundaries. Invalid or unconfigured secret state fails preparation without running a partial job.
- [ ] Every accepted domain contract has Rust unit and integration coverage.
- [ ] Existing PostgreSQL migrations and records pass compatibility tests.
- [ ] Every HTTP and runner route passes request/response parity tests.
- [ ] Durable jobs, outbox delivery, leases, and reconciliation pass crash/duplicate tests.
- [ ] Browser, CLI, server, and runner release acceptance suites pass against Rust artifacts.
- [ ] Production cutover and rollback are documented and rehearsed.
- [ ] Elixir/Phoenix sources and build dependencies are removed.

## Open questions

- Select the server-rendered and real-time browser approach that replaces LiveView without weakening UX requirements.

## Out of scope / future work

- Behavioral changes unrelated to the runtime migration.
