# PLAT-002 — Clean application architecture

## Status

- **State:** Shipped
- **Owner:** Platform
- **Target:** MVP
- **Last updated:** 2026-08-18

## Summary

Robine is one Cargo workspace whose dependency direction points inward. Framework-independent domain contracts live in `robine-core`; orchestration lives in `robine-application`; SQLx, Docker, provider, storage, secret, Actix, CLI, and runner crates are adapters or delivery surfaces. Business decisions are testable without starting Actix, PostgreSQL, Docker, or a worker loop.

## Problem

A CI product touches source-control providers, Docker, object storage, PostgreSQL, durable jobs, HTTP, browser delivery, and remote runners. If lifecycle or authorization rules live inside Actix handlers, SQL queries, Tokio loops, or vendor clients, the behavior becomes difficult to reuse and unsafe to change. Clean architecture must protect those volatile boundaries without creating a trait or wrapper for every pure function.

## Goals

- Keep domain state machines independent from delivery and infrastructure crates.
- Express volatile outbound capabilities as business-oriented Rust traits.
- Reuse the same application operations from HTTP, WebSocket, worker, CLI, and embedded hosts.
- Make transaction and durable-effect boundaries explicit.
- Enforce dependency direction through Cargo structure, compiler visibility, Clippy, and executable tests.

## Non-goals

- A crate, trait, command object, or DTO for every function.
- Runtime dependency-injection containers or global service locators.
- Separate deployable services per bounded context.
- Generic repositories shared by unrelated domains.

## Requirements

### Functional requirements

- **FR-1:** `robine-core` MUST contain framework-independent entities, value objects, state transitions, errors, execution context, and outbound port traits.
- **FR-2:** Core code MUST NOT depend on Actix, SQLx, Docker, provider SDKs, filesystems, process state, or concrete adapters.
- **FR-3:** `robine-application::ControlPlane` MUST be the public orchestration boundary for delivery and embedded callers.
- **FR-4:** Application operations MUST accept typed inputs or narrow ordinary values and return `Result<T, ApplicationError>` for expected outcomes.
- **FR-5:** Actor, tenant, capability, and correlation metadata MUST be supplied through a validated `ExecutionContext` where host-owned authorization is required.
- **FR-6:** Application code MUST depend on context-owned capability traits, not vendor APIs or generic HTTP clients.
- **FR-7:** Concrete implementations MUST remain in adapter crates: `robine-persistence`, `robine-execution`, `robine-source`, `robine-storage`, `robine-secrets`, and `robine-oidc`.
- **FR-8:** Actix handlers, native CLI commands, runner transport, and Tokio workers MUST call application or published domain boundaries rather than issue business SQL or duplicate state machines.
- **FR-9:** SQLx row types and transport values MUST be mapped at adapter boundaries and MUST NOT become public domain types.
- **FR-10:** Concrete adapter construction MUST occur in `robine-server` or an embedding host, never inside a use case.
- **FR-11:** Pure domain or application tests MUST be able to use explicit fakes without changing environment variables or global mocks.
- **FR-12:** Typed stable errors MUST be translated by each delivery surface into HTTP status, CLI exit class, protocol acknowledgement, or retry/dead-letter outcome.
- **FR-13:** Query projections MUST pass through named application/port operations; Actix delivery MUST NOT issue arbitrary SQL.
- **FR-14:** The application operation defines the atomic business boundary and the PostgreSQL adapter implements it without exposing SQLx transactions to delivery code.
- **FR-15:** Network, Docker, and filesystem effects MUST remain outside database transactions. Required post-commit effects MUST be represented by durable outbox or job records.
- **FR-16:** Long-running execution MUST be modeled as bounded claims and durable transitions rather than one transaction or request spanning a CI job.
- **FR-17:** Cross-domain access MUST use public types or application methods, never another crate's private implementation detail.
- **FR-18:** Architecture and contract coverage MUST be executable and fail when a governed specification loses Rust evidence.

### Developer experience requirements

- **DX-1:** Crate names and public modules MUST make core, application, adapter, and delivery ownership discoverable.
- **DX-2:** A domain or application unit test MUST run without external services.
- **DX-3:** Strict compiler warnings and Clippy MUST reject unsafe or ambiguous boundary code.
- **DX-4:** The repository MUST document one complete reference vertical slice from delivery through durable persistence.
- **DX-5:** Adding an adapter MUST not change domain policy unless the business capability changes.

### Operational requirements

- **OR-1:** Production assembly MUST fail closed when required configuration, schema, keys, or adapters are missing.
- **OR-2:** Background loops MUST be shutdown-aware and call bounded, independently retryable application batches.
- **OR-3:** Telemetry failure MUST NOT alter a committed business outcome.
- **OR-4:** Application operations MUST NOT spawn or supervise long-lived tasks.

## Design

Dependencies point inward:

```text
Actix / CLI / runner / Tokio loops
                 |
                 v
        robine-application
          |             |
          v             v
     robine-core   capability traits
                         ^
                         |
 SQLx / Docker / source / storage / secrets / OIDC
```

`ControlPlane` receives `Arc<dyn Trait>` adapters through `new` and typed `with_*` assembly methods. It contains orchestration but no Actix request, SQLx pool, Docker command, or provider client type. `ExecutionContext::embedded` rejects blank tenants and empty capabilities; context-backed queries derive scope from the context rather than caller filters.

The PostgreSQL adapter owns transactions and persists aggregate changes with their outbox records. Post-commit workers use `SKIP LOCKED`, stable idempotency keys, bounded retry, stale-claim recovery, and dead-letter state. The execution adapter consumes a normalized framework-independent specification.

The canonical implementation witness is [the Rust vertical slice](../../architecture/reference-vertical-slice.md). The governed coverage index is [rust-contract-coverage.md](../../operations/rust-contract-coverage.md).

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Required adapter absent | Assembly or affected operation fails closed | Supply the adapter and restart |
| Adapter returns malformed data | Boundary returns a typed infrastructure error | Fix adapter; retry only when safe |
| Expected policy failure | Delivery translates the stable error | Follow domain-specific recovery |
| External effect fails after commit | Durable job remains retryable or dead-letters | Retry/reconcile without rolling back state |
| Forbidden dependency introduced | Compiler, Clippy, or architecture test fails | Move logic inward or introduce a capability port |

## Security and privacy

Authorization executes in application/domain policy; route visibility is never the boundary. Tenant scope comes from trusted server-side context. Secret-bearing values use dedicated redacted/zeroizing types and are mapped only at the narrow execution boundary. Adapter errors and telemetry expose bounded classifications rather than payloads or credentials.

## Testing strategy

- Pure tests cover state transitions, validation, scheduling, conditions, and retry policy.
- Application tests cover orchestration with deterministic inputs.
- Port and adapter tests cover PostgreSQL, Docker, provider HTTP fixtures, storage, and cryptography.
- Delivery tests cover authentication, authorization handoff, request mapping, and response/protocol translation.
- PostgreSQL tests cover tenant isolation, transactions, concurrency, replay, stale claims, and crash windows.
- The contract-coverage test requires unit and integration evidence for every accepted, implementing, or shipped specification.

## Acceptance criteria

- [x] The core crate compiles without delivery or infrastructure framework dependencies.
- [x] Application operations are shared by Actix, workers, CLI or embedded boundaries where applicable.
- [x] Unit tests run without starting Actix or external services.
- [x] SQLx rows and transactions never appear in public core/application types.
- [x] External network or Docker effects never execute inside a database transaction.
- [x] Durable outbox/job tests prove idempotent recovery after missing or stale workers.
- [x] Production adapters are assembled only at the binary or embedding composition root.
- [x] Context-backed PostgreSQL integration tests prove explicit tenant isolation even when RLS is bypassed by the test role.
- [x] Strict Clippy, dependency policy, and the complete workspace suite pass.

## Open questions

None blocking.

## Out of scope / future work

- Separate deployable services per bounded context.
- Dynamic plugin loading and user-provided application modules.
- Event sourcing as the default persistence model.
- Distributed transactions.
