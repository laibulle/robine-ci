# SCM-002 — GitHub-only product surface

## Status

- **State:** Shipped
- **Owner:** Integrations
- **Target:** MVP
- **Last updated:** 2026-08-19

## Summary

Robine exposes GitHub as its only source-control provider for the MVP. Previously implemented provider adapters may remain dormant internally, but they are absent from user journeys, public webhook routing, administration, health presentation, and operator documentation.

## Problem

Advertising and accepting providers that are not part of the current product scope creates unsupported setup paths and makes the UI promise behavior the team does not want to ship yet.

## Goals

- Present one coherent GitHub-only setup and repository journey.
- Prevent deferred provider webhooks and forged LiveView events from activating hidden journeys.
- Preserve dormant adapter code and persisted identity compatibility for a later product decision.

## Non-goals

- Deleting provider-neutral domain boundaries, schemas, migrations, adapters, or their contract tests.
- Migrating or deleting previously persisted non-GitHub records.
- Defining when another provider will be reintroduced.

## Users and use cases

### Primary user

An administrator connecting a GitHub App and explicitly trusting GitHub repositories for CI execution.

### Use cases

1. Configure the GitHub App from Instance Administration.
2. Discover and trust GitHub repositories.
3. Receive authenticated GitHub webhooks and inspect GitHub-backed repository health.

## Requirements

### Functional requirements

- **FR-1:** Public source-control webhook routing MUST expose only the GitHub endpoint.
- **FR-2:** Repository discovery and trust actions reachable from LiveView MUST accept only GitHub.
- **FR-3:** Repository lists and direct repository pages MUST expose only GitHub-backed repositories.
- **FR-4:** Dormant adapter code and durable provider identity MAY remain in the application for future reactivation.

### UX requirements

- **UX-1:** Repository filters, connection controls, setup forms, health cards, and repository pages MUST NOT mention deferred providers.
- **UX-2:** Operator-facing installation and supported-platform documentation MUST describe GitHub as the only supported source-control provider.

### Operational requirements

- **OR-1:** Removing public exposure MUST NOT delete existing records or weaken the provider-neutral architecture boundaries.
- **OR-2:** Reintroducing a provider MUST require an explicit specification change, restored routes and UI, and end-to-end verification.

## Proposed design

Keep provider-neutral domain and adapter modules intact. Restrict the Phoenix delivery layer to GitHub routes and events, filter repository projections to GitHub before rendering, and filter dormant integration checks from the administrator health projection.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Request to a deferred webhook path | HTTP 404 with no delivery persisted | Use the supported GitHub webhook endpoint |
| Direct URL for a dormant repository | Repository-not-found journey | Return to the GitHub repository list |
| Dormant provider health is degraded | No deferred-provider card appears in administration | No operator action required |

## Security and privacy

Hidden controls are not treated as authorization. Deferred webhook routes and LiveView event handlers are removed so crafted requests cannot activate the dormant delivery paths. Existing encrypted secrets and records are retained without being displayed.

## Observability

GitHub and control-plane checks remain visible. Dormant provider checks may continue internally while their labels and details are excluded from the public administration projection.

## Acceptance criteria

- [x] Repository and administration pages contain no deferred-provider controls or labels.
- [x] Deferred webhook paths return 404.
- [x] Only GitHub repositories can be discovered, listed, or opened through the web UI.
- [x] GitHub setup, discovery, webhooks, and repository pages continue to pass their tests.

## Open questions

- None.

## Out of scope / future work

- Reintroducing additional source-control providers after an explicit product decision.
