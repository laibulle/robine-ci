# OPS-001 — Observability and health

## Status

- **State:** Accepted
- **Owner:** Robine maintainers
- **Target:** MVP
- **Last updated:** 2026-08-09

## Summary

Robine provides secret-safe health signals and operational diagnostics so self-hosting operators can detect failures before they lose CI work.

## Problem

An operator needs to distinguish a dead web process from an instance that is alive but cannot safely accept work, and then identify the failing dependency without exposing credentials publicly.

## Goals

- Provide stable liveness and readiness endpoints for container orchestrators.
- Give administrators actionable dependency health in the web interface.
- Correlate work across ingress, durable jobs, pipelines, attempts, and integrations.
- Define the minimum MVP metrics and alerts.

## Non-goals

- Providing a hosted monitoring backend.
- Publishing dependency details on unauthenticated endpoints.
- Treating optional integration degradation as control-plane unavailability.

## Users and use cases

### Primary user

A self-hosting administrator operating one Robine instance.

### Use cases

1. An orchestrator probes whether the HTTP process is alive.
2. A load balancer determines whether the instance can accept durable work.
3. An administrator diagnoses PostgreSQL, queue, storage, Docker, GitHub, or OIDC degradation.

## Requirements

### Functional requirements

- **FR-1:** `GET /health/live` MUST avoid external dependency checks and return HTTP 200 while the web process can serve requests.
- **FR-2:** `GET /health/ready` MUST return HTTP 200 only when PostgreSQL, the durable queue, and blob storage are usable; otherwise it MUST return HTTP 503.
- **FR-3:** Public probes MUST expose only an overall status and timestamp.
- **FR-4:** Authenticated administrators MUST see individual dependency states and secret-free remediation context.
- **FR-5:** Docker, GitHub, and optional OIDC degradation MUST be visible without making the control plane unready.

### UX requirements

- **UX-1:** The administration page MUST display each dependency with a concise status and explanation.
- **UX-2:** An administrator MUST be able to refresh the projection without a full page navigation.
- **UX-3:** Degraded optional services MUST be visually distinct from required-service failures.

### Operational requirements

- **OR-1:** Health output, logs, metrics, and errors MUST NOT contain secrets, tokens, private keys, webhook bodies, or OIDC client secrets.
- **OR-2:** Dependency checks MUST be bounded by timeouts.
- **OR-3:** Correlation identifiers MUST survive durable queue boundaries.
- **OR-4:** Metrics cardinality MUST be bounded and MUST NOT use repository names, commit SHAs, user identifiers, or error messages as labels.

## Proposed design

The `Robine.Operations` facade delegates to an administrator-authorized health use case. The use case depends on a health port, implemented by the system adapter. Public Phoenix controllers project only overall readiness; the administrator LiveView renders the complete secret-free result. Liveness remains a delivery-only process probe because it intentionally performs no application dependency work.

The event outbox reports pending, five-minute-stale, and dead-letter counts in authenticated instance health. A minute-level reconciler recreates missing delivery jobs for every undelivered event. Delivery retries use exponential backoff capped at 30 minutes, and delivery outcomes plus reconciliation counts emit bounded `[:robine, :outbox, ...]` telemetry events.

Structured event logging is owned by a single redaction-safe adapter. Its metadata allowlist contains only bounded correlation, delivery, repository, pipeline, job, attempt, runner, provider-method, state, and outcome dimensions. Unknown keys and complex values are discarded or reduced to `invalid`; URLs, payloads, commands, output, errors, repository names, commit SHAs, user email, credentials, and secret values are never accepted. A GitHub delivery correlation ID is persisted with every created pipeline and restored into runner execution context, so the webhook, durable delivery, pipeline, job, attempt, local runner, and sanitized GitHub API events can be joined after queue boundaries.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| PostgreSQL unavailable | Readiness returns 503 and admin health reports database failure | Restore PostgreSQL connectivity; the next probe recovers automatically |
| Blob path not writable | Readiness returns 503 without disclosing the path | Restore permissions or capacity and refresh |
| Docker unavailable | Readiness remains 200 while execution health is degraded | Restore Docker before dispatching jobs |
| GitHub or OIDC unconfigured | Integration is marked degraded or optional | Configure the integration or leave it intentionally disabled |

## Security and privacy

Detailed health is restricted to administrators. Public responses contain no component inventory or configuration. Probe implementations reduce failures to fixed messages and never interpolate credentials or raw provider errors.

## Observability

The MVP exposes the `Telemetry.Metrics` catalogue in Prometheus 0.0.4 text format at `GET /metrics`. Export is disabled, and the route returns HTTP 404, unless `ROBINE_METRICS_TOKEN` is configured. An enabled endpoint requires `Authorization: Bearer <token>`, compares only SHA-256 digests in constant time, returns HTTP 401 for invalid credentials, and never caches a scrape. Operators MUST terminate TLS before exposing the endpoint outside a private network.

The catalogue uses counters, gauges, and bucketed distributions with bounded labels for HTTP failures, queue depth and age, pipeline/job outcomes and duration, runner loss, storage usage, outbox failures, GitHub rate limiting, and authentication anomalies. It MUST NOT use repository names, commit SHAs, user identifiers, URLs, messages, or credentials as labels. Structured events MUST include correlation IDs where applicable.

## Acceptance criteria

- [x] Liveness returns HTTP 200 without checking dependencies.
- [x] Readiness returns only overall status and a timestamp.
- [x] Required dependency failure produces HTTP 503.
- [x] Administrators can inspect and refresh dependency health.
- [x] Automated tests prove public probes do not expose component details or configured secrets.
- [x] Structured events correlate GitHub delivery through local runner execution and reject non-allowlisted secret-bearing metadata.
- [x] All required MVP metrics have bounded labels and tests.
- [x] Alert and troubleshooting guidance is published.

The initial alert catalogue and remediation procedures are published in `docs/operations/monitoring-and-troubleshooting.md`.

## Out of scope / future work

- OpenTelemetry trace export and managed-cloud fleet aggregation.
