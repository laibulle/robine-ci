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

## Observability

The Rust runtime publishes compatible health and Prometheus endpoints, structured correlation IDs, queue/dispatch/storage metrics, and audit events. During staged migration, parity mismatches are counted without logging sensitive payloads.

## Acceptance criteria

- [x] A Cargo workspace builds with a framework-free core crate and an Actix server crate.
- [x] The Actix server implements tested liveness and readiness routes at the existing paths.
- [x] Rust execution-context validation rejects missing tenants and capabilities.
- [x] SQLx connects to the existing migrated PostgreSQL schema and scopes reads through the existing row-level-security tenant setting.
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
