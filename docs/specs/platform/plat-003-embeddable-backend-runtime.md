# PLAT-003 — Embeddable backend runtime

## Status

- **State:** Shipped
- **Owner:** Robine maintainers
- **Target:** Post-MVP
- **Last updated:** 2026-08-12

## Summary

Robine CI can run either as its standalone Actix product or as a backend engine assembled by another Rust application. Embedded consumers own the complete human interface, authentication, navigation, supervision, and visual integration; Robine publishes framework-independent crates and explicit adapter boundaries.

## Problem

An embedding host must be able to reuse Robine without starting its Actix endpoint, standalone identity system, UI, or implicit workers. Every host call still needs an explicit tenant and capability boundary.

## Goals

- Preserve the standalone Robine CI product.
- Let a host supervise the CI backend without starting Robine's human endpoint or identity delivery.
- Carry a mandatory tenant and explicit capabilities for embedded calls.
- Keep authorization and tenant isolation inside Robine's backend boundary.
- Publish stable Rust entry points and Rust-owned schema bootstrap metadata for consumers.

## Non-goals

- Sharing LiveViews, layouts, components, assets, hooks, or navigation.
- Mapping a host application's roles automatically.
- Allowing consumers to query Robine Ecto schemas directly.

## Users and use cases

### Primary user

An OTP application such as Robine Workspace that wants to expose CI with its own interface and identity model.

### Use cases

1. A standalone release starts the complete Robine product unchanged.
2. A host assembles `ControlPlane` without Actix and supplies actor, tenant, and capabilities for each backend call.
3. A host applies the versioned Rust schema bootstrap to a dedicated PostgreSQL database.

## Requirements

### Functional requirements

- **FR-1:** Robine MUST expose framework-independent `robine-core` and `robine-application` library boundaries for host assembly.
- **FR-2:** The standalone `robine-server` binary MUST assemble the current web product, identity delivery, adapters, and shutdown-aware workers.
- **FR-3:** Constructing the embedded `ControlPlane` MUST NOT start Actix, human authentication delivery, UI assets, or background tasks.
- **FR-4:** Embedded callers MUST construct contexts with a non-empty tenant ID and explicit capabilities.
- **FR-5:** Backend authorization MUST be evaluated by Robine and MUST NOT trust a UI-supplied repository or tenant filter as an isolation boundary.
- **FR-6:** The host MUST own all human UI and authentication in embedded mode.
- **FR-7:** Robine MUST publish its Rust-owned schema bootstrap and version so a host can migrate without copying SQL into its source tree.

### UX requirements

- **UX-1:** None. This contract deliberately exports no UI.

### Operational requirements

- **OR-1:** The host MUST own Tokio task supervision, restart policy, shutdown signals, and adapter sharing.
- **OR-2:** Runtime assembly MUST fail fast on incomplete adapters or embedded contexts.
- **OR-3:** Tenant-owned durable records MUST be isolated in persistence queries and constraints.
- **OR-4:** Embedded deployment SHOULD use a dedicated PostgreSQL database or restricted role to avoid host-table collisions.

## Proposed design

`robine-server` explicitly assembles `Database`, `ControlPlane`, adapters, Actix delivery, and shutdown-aware Tokio workers. An embedded host constructs the same `ControlPlane` library value with only the adapters it needs; construction has no process or network side effects.

`ExecutionContext` contains `actor`, `tenant_id`, `capabilities`, and `correlation_id`. Standalone contexts use the reserved tenant `"standalone"` and translate instance roles into capabilities. Embedded contexts accept host identifiers as opaque strings and never depend on a host schema. `ControlPlane::list_pipelines_for_context` is the reference public embedded query and derives scope only from that validated context.

The public integration boundary consists of context types, application methods, ports, explicit adapters, bounded worker methods, and Rust schema bootstrap. SQLx record details and Actix delivery remain private to their adapter crates.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Missing adapter | Assembly or the affected operation fails closed | Supply the required typed adapter |
| Missing tenant or capabilities | Context construction returns an error | Supply an authorized host scope |
| Host does not bootstrap the schema | Persistence fails closed | Run `Database::bootstrap_schema()` |
| Worker task exits | Host supervisor observes task completion | Apply the host's restart or shutdown policy |

## Security and privacy

Tenant IDs and capabilities are trusted only when supplied by the host's server-side integration. Every tenant-owned persistence operation must derive scope from `ExecutionContext`; client parameters cannot override it. Secrets, logs, artifacts, and runner credentials remain backend-only data.

## Observability

The Cargo package version is available at compile time. Existing health queries, audit records, outbox state, and bounded worker results remain available through application boundaries; embedded hosts own logging and task instrumentation.

## Acceptance criteria

- [x] Standalone startup retains the Actix endpoint and existing behavior.
- [x] Constructing an embedded `ControlPlane` starts no Actix endpoint, identity delivery, UI process, or worker.
- [x] A host can run the public Rust schema bootstrap and obtain the Cargo package version.
- [x] Embedded context creation rejects missing tenant IDs and empty capabilities.
- [x] Context-backed operations cannot read or mutate records belonging to another tenant.
- [x] No Actix module is required by the embedded public API.
- [x] The full Rust workspace suite passes.

## Open questions

- None blocking. Runner HTTP/WebSocket delivery remains a host-selected adapter; it is not part of the framework-independent embedded boundary.

## Out of scope / future work

- A Workspace-specific bridge package.
- Shared UI of any kind.
- Cross-tenant administration APIs.
