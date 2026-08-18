# SCM-001 — GitLab and Forgejo integration

## Status

- **State:** Shipped
- **Owner:** Integrations
- **Target:** Post-MVP
- **Last updated:** 2026-08-09

## Summary

Robine connects trusted GitLab.com, self-managed GitLab, and Forgejo repositories through provider-specific adapters behind one source-control capability. Authenticated push and merge/pull-request webhooks resolve exact commit content, create the existing provider-neutral pipeline contract, and project pipeline and job status back to the originating commit.

## Problem

An open-source, self-hosted CI service that only connects to GitHub still forces GitLab and Forgejo users through a proprietary provider. These systems expose similar concepts but materially different authentication, webhook payloads, repository APIs, and status models. Copying GitHub-specific use cases for each provider would drift execution semantics and make security fixes inconsistent.

## Goals

- Connect explicitly trusted GitLab and Forgejo repositories without changing workflow or runner semantics.
- Normalize provider events into one bounded exact-SHA push or change-request contract.
- Publish durable pipeline and job status with stable Robine deep links.
- Preserve GitHub behavior while removing GitHub assumptions from repository-domain and shared use-case code.
- Support self-managed provider base URLs without allowing repository-controlled outbound destinations.

## Non-goals

- GitHub Actions, GitLab CI, Woodpecker, or Forgejo Actions syntax compatibility.
- Arbitrary user-supplied provider URLs per request, unauthenticated repositories, or repository credentials inside workflows.
- Fork execution, merge trains/queues, deployment statuses, comments, releases, or provider-hosted runners.
- Cross-provider mirroring or migrating repository history.

## Users and use cases

### Primary user

An administrator of a self-hosted Robine instance connecting a trusted GitLab or Forgejo project, and developers who expect CI status in their ordinary code-review UI.

### Use cases

1. Configure one allowlisted GitLab or Forgejo provider instance and test its credentials.
2. Discover projects visible to the configured service credential and explicitly trust one.
3. Trigger the same Robine workflow on a branch push or same-repository merge/pull request.
4. Follow a commit status to the corresponding Robine pipeline or job.
5. Continue local execution while a provider status API is temporarily unavailable.

## Requirements

### Functional requirements

- **FR-1:** A repository MUST retain `provider`, immutable provider-instance identity, provider project ID, canonical owner/name, and explicit trust state. Existing GitHub records MUST migrate without identity loss.
- **FR-2:** Supported providers MUST be `github`, `gitlab`, and `forgejo`. GitLab and Forgejo base URLs MUST come from administrator configuration, use HTTPS outside development, contain no userinfo/query/fragment, and be normalized before use.
- **FR-3:** Provider credentials and webhook secrets MUST be administrator-owned, write-only, encrypted instance secrets with environment bootstrap fallbacks. Repository YAML and webhook payloads MUST NOT select credentials or base URLs.
- **FR-4:** GitLab webhooks MUST validate the configured secret token in constant time. Forgejo webhooks MUST validate the provider signature over the exact request body with the configured secret. Authentication MUST precede JSON parsing or persistence.
- **FR-5:** Deliveries MUST be deduplicated by `(provider, provider_instance, delivery_id)` and durably acknowledged before source fetch or pipeline creation.
- **FR-6:** GitLab push and merge-request events and Forgejo push and pull-request events MUST normalize to the existing branch, exact SHA, same-repository change-request, actor, and trigger contract. Draft and fork change requests MUST remain disabled by default.
- **FR-7:** Workflow and source files MUST be fetched from the normalized exact 40-character commit SHA. Adapters MUST reject mutable-ref substitution and malformed or oversized provider responses.
- **FR-8:** Manual and scheduled workflows MUST resolve the exact current default-branch head through the repository's configured provider adapter.
- **FR-9:** Pipeline and job projections MUST use provider commit-status APIs with stable external keys and Robine deep links. Provider limitations MAY collapse presentation but MUST NOT collapse Robine's durable job state.
- **FR-10:** Status delivery MUST remain an outbox-driven, idempotent, retryable projection. A provider outage MUST NOT roll back or stop an already-created Robine pipeline.
- **FR-11:** Discovery MUST query the configured provider credential server-side and require an exact provider-instance, project-ID, and canonical-name match before trust is persisted.
- **FR-12:** All providers MUST execute the same `Workflows.resolve`, pipeline creation, runner, secrets, cache, artifact, matrix, condition, service, manual, schedule, retry, and cancellation contracts.

### UX requirements

- **UX-1:** Repository screens MUST identify provider and configured instance, never infer them only from an icon or repository name.
- **UX-2:** Setup MUST show the exact webhook URL, required provider permissions/scopes, event selection, and corrective action for failed credential or permission checks.
- **UX-3:** Discovery, manual workflows, schedules, and health errors MUST name the relevant provider without exposing tokens, webhook bodies, internal host credentials, or private API URLs to unauthorized users.
- **UX-4:** Existing GitHub routes and journeys MUST remain compatible; GitLab and Forgejo receive dedicated webhook endpoints and provider-neutral repository pages.

### Operational requirements

- **OR-1:** Provider selection MUST occur in the runtime composition root. Shared use cases depend on one context-owned `SourceControl` port and MUST NOT branch on adapter module names.
- **OR-2:** Outbound requests MUST use the configured provider origin only, reject redirects to another origin, apply bounded connect/request timeouts, and cap body/file/list sizes.
- **OR-3:** Provider rate-limit state, request duration/outcome, webhook authentication outcome, delivery duration, and projection reconciliation MUST use bounded provider labels only.
- **OR-4:** Provider health MUST degrade independently; one unavailable optional provider MUST NOT make the durable control plane unready or prevent other providers from operating.
- **OR-5:** Database uniqueness MUST prevent identity collision across providers while allowing equal numeric project IDs and names on distinct configured instances.

## Proposed design

Provider-neutral Rust traits describe repository capabilities: discovery, exact default head, exact workflow/source fetch, permission diagnosis, and status upsert. Binary assembly maps the persisted provider-instance key to a configured adapter; application code selects it for a trusted repository without depending on vendor transport types.

Actix webhook adapters authenticate raw requests and submit a provider-tagged command through `ControlPlane`. Provider-specific pure normalizers convert payloads to the shared event contract. The durable delivery batch then resolves workflows and creates pipelines exactly once. GitHub status projection is active for this cutover; GitLab and Forgejo outbound status adapters are explicitly deferred while their authenticated ingestion remains supported.

Persistence evolves existing tables in place: repository identities gain provider and provider-instance columns; deliveries and status projections gain the same bounded identity. Existing rows backfill to the default GitHub instance. Names may remain legacy implementation details temporarily, but domain contracts and new code are provider-neutral. Unique constraints move from project ID alone to `(provider, provider_instance, provider_project_id)`.

GitLab uses a configured API token with the minimal `read_api`/status-write capability supported by the selected deployment and validates `X-Gitlab-Token`. Forgejo uses a configured token with repository read/status write permissions and validates its HMAC signature header over the raw body. Exact scopes and header algorithms are adapter contracts and integration-tested against pinned provider versions before shipment.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Unknown provider instance | Request is rejected before outbound access | Configure and restart, then retry |
| Invalid webhook authentication | No delivery is persisted; bounded audit/metric emitted | Correct the provider webhook secret |
| Duplicate/reordered event | Existing delivery result or independent exact-SHA result is returned | No action |
| Provider API unavailable | New source resolution fails safely; existing pipelines continue | Bounded retry and reconciliation |
| Status API unsupported or revoked | Local state remains authoritative and projection health degrades | Restore token scope and reconcile |
| Redirect leaves configured origin | Adapter rejects the response as unsafe | Correct provider/proxy configuration |
| Fork change request | No pipeline and no secrets | Review future untrusted-workload policy |
| Migrated GitHub identity collision | Migration stops before changing constraints | Resolve corrupt/duplicate data, then retry |

## Security and privacy

Only administrator-configured origins and credentials are reachable. Private/self-managed hostnames are sensitive operational metadata and are shown only to administrators. Tokens, webhook secrets, authorization headers, payload bodies, source contents, and repository names never enter telemetry or ordinary logs. Constant-time verification, raw-body authentication, redirect-origin enforcement, response limits, and exact-SHA validation are mandatory adapter boundaries. Trusted repository code retains the existing Docker threat model; this feature does not make fork execution safe.

## Observability

Emit `robine.source_control.request` count/duration with bounded `provider`, `operation`, `outcome`, and normalized status class; `robine.source_control.webhook` authentication/acknowledgement; and `robine.source_control.projection` reconciliation outcome. Health reports one bounded configured-instance status to administrators, while Prometheus labels include provider kind but never instance URL, repository, project ID, actor, SHA, token scope value, or error text.

## Acceptance criteria

- [x] Existing GitHub repository, webhook, manual, schedule, and check tests remain green through the provider-neutral port.
- [x] A GitLab push and same-repository merge request each create one exact-SHA pipeline and publish terminal commit statuses.
- [x] A Forgejo push and same-repository pull request each create one exact-SHA pipeline and publish terminal commit statuses.
- [x] Invalid signatures/tokens, forks, mutable refs, cross-origin redirects, oversized responses, and duplicate deliveries create no unauthorized pipeline.
- [x] Equal numeric project IDs on GitHub, GitLab, and Forgejo remain distinct durable repository identities.
- [x] Provider outages preserve local pipeline truth and reconcile status after recovery.
- [x] Manual, schedule, reusable workflow, local runner, and remote runner behavior is identical for every provider.
- [x] Migrations, architecture rules, security scans, pinned-provider integration tests, release smokes, and full QA are green.

## Open questions

None blocking. Initial self-managed support is one administrator-configured instance per provider kind; multiple instances of the same kind remain a follow-up.

## Out of scope / future work

- Bitbucket, Azure DevOps, multiple instances per provider kind, OAuth user delegation, merge queues/trains, provider comments, deployments, and untrusted forks.
