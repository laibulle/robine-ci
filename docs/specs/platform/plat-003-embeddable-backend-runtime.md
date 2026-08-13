# PLAT-003 — Embeddable backend runtime

## Status

- **State:** Shipped
- **Owner:** Robine maintainers
- **Target:** Post-MVP
- **Last updated:** 2026-08-12

## Summary

Robine CI can run either as its standalone product or as a backend engine supervised by another OTP application. Embedded consumers own the complete human interface, authentication, navigation, and visual integration; Robine publishes only backend contracts and runtime children.

## Problem

Starting Robine as a dependency currently starts its Phoenix endpoint, standalone identity system, and UI. Its execution context also has no host-owned tenant boundary. This prevents Robine Workspace from presenting CI as a native product while safely reusing the CI engine.

## Goals

- Preserve the standalone Robine CI product.
- Let a host supervise the CI backend without starting Robine's human endpoint or identity delivery.
- Carry a mandatory tenant and explicit capabilities for embedded calls.
- Keep authorization and tenant isolation inside Robine's backend boundary.
- Publish stable Elixir entry points and migration/runtime metadata for consumers.

## Non-goals

- Sharing LiveViews, layouts, components, assets, hooks, or navigation.
- Mapping a host application's roles automatically.
- Allowing consumers to query Robine Ecto schemas directly.

## Users and use cases

### Primary user

An OTP application such as Robine Workspace that wants to expose CI with its own interface and identity model.

### Use cases

1. A standalone release starts the complete Robine product unchanged.
2. A host starts `Robine.Runtime` with the `:embedded` profile and supplies actor, tenant, and capabilities for each backend call.
3. A host runs versioned Robine migrations in an isolated PostgreSQL prefix.

## Requirements

### Functional requirements

- **FR-1:** Robine MUST expose `Robine.Runtime.child_spec/1` for host supervision.
- **FR-2:** The `:standalone` profile MUST start the current web product and standalone identity services.
- **FR-3:** The `:embedded` profile MUST NOT start Robine's Endpoint, human authentication services, or UI-specific processes.
- **FR-4:** Embedded callers MUST construct contexts with a non-empty tenant ID and explicit capabilities.
- **FR-5:** Backend authorization MUST be evaluated by Robine and MUST NOT trust a UI-supplied repository or tenant filter as an isolation boundary.
- **FR-6:** The host MUST own all human UI and authentication in embedded mode.
- **FR-7:** Robine MUST publish its migration path, default database prefix, and version so a host can run migrations without copying them.

### UX requirements

- **UX-1:** None. This contract deliberately exports no UI.

### Operational requirements

- **OR-1:** The runtime supervisor ID and name MUST be configurable. One engine instance owns Robine's reserved Repo, PubSub, Oban, and adapter process names within a BEAM node.
- **OR-2:** Runtime configuration MUST fail fast on unsupported profiles or incomplete embedded contexts.
- **OR-3:** Tenant-owned durable records MUST be isolated in persistence queries and constraints.
- **OR-4:** Robine tables SHOULD use the `robine_ci` PostgreSQL prefix when embedded to avoid collisions with host tables.

## Proposed design

`Robine.Application` starts `Robine.Runtime` with the configured profile. A dependency declared with `runtime: false` can instead place `{Robine.Runtime, profile: :embedded}` in the host supervision tree. Runtime children are grouped into engine, standalone identity delivery, and standalone web delivery.

`Robine.ExecutionContext` contains `actor`, `tenant_id`, `capabilities`, `correlation_id`, and assembled dependencies. Standalone contexts use the reserved tenant `"standalone"` and translate existing instance roles into capabilities. Embedded contexts accept host identifiers as opaque strings and never depend on a host schema.

The public integration boundary consists of context facades, PubSub/event contracts, runtime supervision, and migration metadata. Ecto schemas and adapters remain private.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Unsupported runtime profile | Startup fails before children start | Correct host configuration |
| Missing tenant or capabilities | Context construction returns an error | Supply an authorized host scope |
| Host does not run migrations | Repo operations fail and health reports storage unavailable | Run published migrations |
| Duplicate engine instance | Reserved engine child names reject the second instance | Run one engine per BEAM node |

## Security and privacy

Tenant IDs and capabilities are trusted only when supplied by the host's server-side integration. Every tenant-owned persistence operation must derive scope from `ExecutionContext`; client parameters cannot override it. Secrets, logs, artifacts, and runner credentials remain backend-only data.

## Observability

Runtime profile and package version are available as metadata. Existing health, telemetry, audit, and outbox facilities remain active for engine children. Embedded hosts may attach their own telemetry handlers.

## Acceptance criteria

- [x] Standalone startup retains the Endpoint and existing behavior.
- [x] Embedded startup has a live engine Repo/PubSub/Oban tree and no Robine Endpoint or login/identity delivery process.
- [x] A host can obtain migration path, prefix, and package version from a public module.
- [x] Embedded context creation rejects missing tenant IDs and empty capabilities.
- [x] Context-backed operations cannot read or mutate records belonging to another tenant.
- [x] No RobineWeb module is required by the embedded public API.
- [x] The full precommit suite passes.

## Open questions

- None blocking. Runner HTTP/WebSocket delivery will be mounted by a host adapter in a later contract; it is not the human UI endpoint.

## Out of scope / future work

- A Workspace-specific bridge package.
- Shared UI of any kind.
- Cross-tenant administration APIs.
