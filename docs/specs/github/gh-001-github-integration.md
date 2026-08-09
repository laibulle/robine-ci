# GH-001 — GitHub integration

## Status

- **State:** Accepted
- **Owner:** Integrations
- **Target:** MVP
- **Last updated:** 2026-08-09

## Summary

Robine integrates with GitHub through a GitHub App, consumes authenticated push and pull-request webhooks, fetches exact commit content, and publishes one check suite with job-level check runs.

## Problem

Developers need CI to start automatically and report results where code review occurs. The integration must minimize repository permissions, handle duplicate or reordered events, and remain useful during temporary GitHub outages.

## Goals

- Connect selected repositories through least-privilege GitHub App permissions.
- Trigger workflows on supported events and filters.
- Report queued, active, and terminal status with links to Robine.
- Process webhooks idempotently and asynchronously.

## Non-goals

- OAuth applications as the primary repository integration.
- GitHub Actions compatibility.
- GitHub Enterprise Server in the initial MVP unless separately validated.
- Forked public contribution security.

## Users and use cases

### Primary user

A repository administrator installing the Robine GitHub App and contributors reading checks on commits and pull requests.

### Use cases

1. Install the app on selected repositories.
2. Start workflows on matching pushes or pull requests.
3. Open Robine from a GitHub check to inspect logs.
4. Receive correct status despite webhook retries or API interruptions.

## Requirements

### Functional requirements

- **FR-1:** The setup UI MUST generate or guide creation of a GitHub App with the minimum documented permissions.
- **FR-2:** Every webhook MUST pass GitHub signature verification before payload processing.
- **FR-3:** Webhook deliveries MUST be deduplicated by delivery ID.
- **FR-4:** The HTTP webhook endpoint MUST persist an accepted delivery and respond before performing clone, parsing, or execution work.
- **FR-5:** Supported triggers MUST include `push` and `pull_request` opened, reopened, synchronized, and ready-for-review actions.
- **FR-6:** Branch filters MUST match the target branch for pull requests and pushed branch for push events.
- **FR-7:** Workflow content and source code MUST be fetched for the exact event commit SHA.
- **FR-8:** Robine MUST create a check suite for the pipeline and a check run for each job, with links to the corresponding Robine pages.
- **FR-9:** Check updates MUST be idempotent and retried with exponential backoff and jitter.
- **FR-10:** Superseding a pipeline for the same pull request and workflow MAY be instance-configurable, but MUST default to cancelling older queued attempts, not active attempts.
- **FR-11:** Pull requests from forks MUST not receive secrets and MUST be disabled by default in the trusted-repository MVP.

### UX requirements

- **UX-1:** Setup MUST show missing permissions and the exact corrective action.
- **UX-2:** Repository pages MUST display last webhook time and integration health without exposing payload secrets.
- **UX-3:** GitHub check summaries MUST identify the failed job and step and link directly to its logs.

### Operational requirements

- **OR-1:** Accepted webhook processing MUST tolerate duplicate and reordered delivery.
- **OR-2:** Installation access tokens MUST be cached only within their validity period and refreshed safely.
- **OR-3:** GitHub rate-limit state MUST be monitored and visible to operators.

## Proposed design

The installation wizard asks the operator for the public callback URL and produces exact manual GitHub App setup instructions. The App ID remains non-secret configuration. Administrators store the private key and webhook secret as write-only instance credentials encrypted by the shared versioned AES-256-GCM secret subsystem; environment values remain bootstrap and break-glass fallbacks. Webhook ingestion stores delivery metadata and a minimal payload, then schedules event normalization. Normalized events select workflow revisions and create pipelines transactionally.

Installation access-token responses supply the effective permission projection cached with the token expiry. Repository operators can run a live preflight against the accepted least-privilege policy: Metadata read, Contents read, and Checks write. Every mismatch includes its current value and the exact GitHub App permission update and installation-approval action.

The repository selection UI discovers active installations and all paginated repositories directly through GitHub App credentials. Selecting a repository sends only an untrusted candidate tuple; the application rediscovers current App access and requires an exact repository ID, installation ID, and full-name match before creating the trusted-repository record. Suspended installations are excluded and discovery failures never fall back to browser-supplied metadata.

Checks are projections of Robine state rather than the source of truth. Delivery failures never roll back local pipeline state. A reconciliation job repairs stale or missing checks.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Invalid signature | Request is rejected and audited | Correct webhook secret/configuration |
| Duplicate webhook | Existing delivery result is returned | No user action |
| GitHub API outage | Pipeline continues locally; check is marked delivery-pending | Automatic retry and reconciliation |
| Permission revoked | Integration health becomes degraded | Reinstall or update app permissions |
| Commit cannot be fetched | Pipeline fails before execution with source error | Restore access or retry |

## Security and privacy

The app requests only metadata/content read access and checks write access required by the accepted implementation. Private keys and webhook secrets are encrypted. Raw webhook retention is bounded and payloads are never written to normal application logs.

## Observability

Every GitHub API and installation-token request emits bounded latency and outcome dimensions plus rate-limit remaining, limit, and reset values when GitHub supplies them. No URL, repository name, response body, credential, or payload becomes telemetry metadata. The latest sanitized result is retained in process memory and exposed through administrator integration health; exhaustion or API errors degrade the check. The broader metrics catalogue also includes webhook verification failures, acknowledgement latency, processing latency, duplicate rate, and check reconciliation count.

## Acceptance criteria

- [ ] Replaying a webhook delivery does not create another pipeline.
- [ ] A matching push and pull request each run the workflow from their exact commit.
- [ ] A failed job appears as a failed GitHub check with a deep link to logs.
- [ ] A temporary GitHub API failure does not stop local execution and is reconciled later.
- [ ] A fork pull request receives no secret-bearing execution by default.

## Open questions

None blocking for the MVP. Draft pull requests are ignored until `ready_for_review`; GitHub.com is the supported MVP target.

## Out of scope / future work

- GitLab, Forgejo, Bitbucket, merge queues, deployment statuses, and automatic PR comments.
