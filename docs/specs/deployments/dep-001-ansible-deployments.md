# DEP-001 — Ansible deployments

## Status

- **State:** Accepted
- **Owner:** Robine maintainers
- **Target:** Post-MVP
- **Last updated:** 2026-08-25

## Summary

Robine turns a successful CI pipeline into a controlled deployment by running an explicitly configured playbook from a shared Ansible repository, retaining a secret-safe audit trail and verifying the deployed service before declaring success.

## Problem

Self-hosting operators commonly keep reusable deployment recipes in a repository separate from application source. They need to connect those recipes to CI without distributing unrestricted SSH credentials, losing the relationship between a commit and its deployment, or searching several systems to understand a failure.

## Goals

- Make staging and production deployments visible from the repository and pipeline experience.
- Reuse an existing shared Ansible repository without copying playbooks into application repositories.
- Record who deployed which application revision, with which immutable recipe revision, to which environment.
- Reuse bounded live logs, secret redaction, cancellation, and runner isolation.
- Verify a deployment with a bounded HTTP health check.

## Non-goals

- Reimplementing Ansible, editing playbooks, or managing a general-purpose inventory in Robine.
- Providing an interactive SSH terminal or arbitrary commands from the web interface.
- Replacing Prometheus, Grafana, Alertmanager, or infrastructure monitoring.
- Automatically inferring or executing rollback behavior.
- Supporting untrusted pull-request deployment code.

## Users and use cases

### Primary user

A self-hosting administrator who deploys trusted application repositories with a shared Ansible recipe repository.

### Use cases

1. An administrator connects one trusted Ansible repository and configures an application environment.
2. A developer deploys a successful exact application revision to staging.
3. An authorized administrator approves and deploys an exact revision to production.
4. An operator follows redacted Ansible output and the post-deployment health check from one deployment page.
5. An operator redeploys a previously recorded pair of application and recipe revisions.

## Requirements

### Functional requirements

- **FR-1:** An administrator MUST configure the shared recipe repository, default branch, and provider connection before creating an environment.
- **FR-2:** An environment MUST belong to one application repository and define a unique lowercase name, protection mode, playbook path, inventory path, allowed runner labels, health-check URL, and deployment timeout.
- **FR-3:** Environment configuration MUST reference repository-relative playbook and inventory paths; absolute paths and traversal segments MUST be rejected.
- **FR-4:** Every deployment MUST record the application repository and exact commit SHA, recipe repository and resolved exact commit SHA, environment configuration snapshot, actor, source pipeline, timestamps, and outcome.
- **FR-5:** A deployment MUST only start from a successful pipeline for the same exact application commit and trusted repository.
- **FR-6:** Staging MAY allow deployment by a repository maintainer. Production MUST require a separate administrator approval after the deployment is requested.
- **FR-7:** Robine MUST execute `ansible-playbook` as a runner job with a generated, attempt-scoped execution specification rather than invoking a shell from the web process.
- **FR-8:** A deployment MUST transition through `requested`, `awaiting_approval`, `queued`, `running`, and one terminal state of `succeeded`, `failed`, `cancelled`, or `verification_failed`; invalid transitions MUST be rejected by the domain.
- **FR-9:** Only one deployment MAY run per environment. Additional approved deployments MUST remain queued in request order.
- **FR-10:** Ansible output MUST use the existing cursor-based log transport, phase grouping, retention, and redaction pipeline.
- **FR-11:** After Ansible succeeds, Robine MUST perform the configured HTTP health check with `Req`, bounded timeouts, no redirects to a different origin, and a configurable expected status range defaulting to 200–299.
- **FR-12:** Redeploy MUST create a new deployment using the recorded exact application and recipe revisions. Rollback MUST be represented by an explicitly configured playbook and MUST NOT be inferred from deployment history.
- **FR-13:** Cancellation MUST use the existing runner cancellation protocol and MUST leave the deployment terminal even if remote changes cannot be reverted.

### UX requirements

- **UX-1:** A repository page MUST show each environment, its latest deployment, deployed application revision, health state, and active deployment.
- **UX-2:** A deployment page MUST show environment, actor, approval, application and recipe revisions, pipeline link, state timeline, grouped live logs, and verification result.
- **UX-3:** Production approval MUST summarize the exact revisions and target environment and require an explicit confirmation action.
- **UX-4:** Failed states MUST distinguish playbook failure, cancellation, runner loss, timeout, and post-deployment verification failure.
- **UX-5:** Buttons MUST expose disabled and loading states and prevent duplicate submission.

### Operational requirements

- **OR-1:** Recipe checkout, inventory preparation, credentials, Ansible execution, and cleanup MUST occur in an attempt-scoped runner workspace.
- **OR-2:** Recipe and application revisions MUST be resolved before approval and MUST NOT move while a request awaits approval.
- **OR-3:** SSH keys, vault passwords, become passwords, inventory variables, environment secrets, host addresses marked secret, and generated temporary paths MUST NOT be persisted in deployment records or emitted in logs.
- **OR-4:** Deployment requests, approvals, cancellation, secret access, start, completion, and verification MUST emit durable audit events.
- **OR-5:** The runner MUST clean generated inventory fragments, SSH material, and vault password files after every terminal outcome.
- **OR-6:** Deployment concurrency and timeout limits MUST be bounded independently from CI job limits.
- **OR-7:** Delivery code MUST call a `Robine.Deployments` facade; domain and use-case code MUST remain independent from Phoenix, Ecto, Ansible, Docker, and concrete adapters.

## Proposed design

`Robine.Deployments` is a bounded context containing pure `Environment`, `Deployment`, and transition policy modules. Its use cases own authorization and coordinate context-owned repository, recipe-source, execution, verification, audit, clock, and identifier ports. Concrete Ecto, source-control, runner, and Req implementations live under `Robine.Adapters` and are assembled by `Robine.Runtime.Dependencies`.

An environment stores deploy policy and secret references, never secret values. A request resolves both source revisions and snapshots non-secret environment configuration before any approval. Approval queues a generated deployment execution specification on a compatible runner. The specification checks out the shared recipe revision and invokes a fixed executable and argument vector; user-controlled values are never concatenated into a shell command. Runner events feed existing redacted logs while deployment state is projected independently from pipeline state.

After a successful playbook, a verification use case calls a deployment-owned HTTP verifier port implemented with Req. Verification failure does not claim the playbook was reverted: it produces `verification_failed` and exposes a safe retry-verification action.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Recipe revision cannot be resolved | Request is rejected before approval | Restore provider access or select a valid branch and retry |
| No compatible runner | Deployment remains queued with a capacity explanation | Bring an allowed runner online or change environment labels |
| Ansible exits non-zero | Deployment becomes `failed` and retains redacted output | Correct the recipe or target, then create a new deployment |
| Runner disconnects | Existing lease recovery applies; final loss becomes `failed` | Reconcile the runner and redeploy after assessing target state |
| Health check fails | Deployment becomes `verification_failed` without automatic rollback | Inspect monitoring, retry verification, or run an explicit rollback playbook |
| Cancellation races completion | First persisted terminal transition wins | Inspect the recorded timeline and target state before another deployment |

## Security and privacy

Only trusted repositories may deploy. Repository maintainers may request allowed staging deployments; administrators configure environments, approve production, manage secret references, and cancel any deployment. The requesting actor cannot approve their own production request. Source checkouts use existing provider credentials and runners receive only attempt-scoped secret material. Paths are normalized and confined to their checkout roots. Ansible is invoked without a shell and with host-key verification enabled by default. Disabling host-key verification is not supported by this specification.

## Observability

Robine emits bounded counters and distributions for requests, approvals, queue time, execution duration, terminal outcome, cancellation, and verification. Labels are limited to environment protection mode, phase, outcome, and verification class; repository names, environment names, revisions, hosts, URLs, actors, errors, and log output are forbidden labels. Structured events carry deployment, pipeline, job, and attempt correlation identifiers. The administration health projection reports whether recipe source and deployment-capable runners are configured, without making the CI control plane unready.

## Acceptance criteria

- [ ] An administrator can configure staging and protected production environments using one shared recipe repository.
- [ ] A successful exact pipeline revision can be deployed to staging and traced through retained redacted logs.
- [ ] Production requires approval by an administrator other than the requester, with revisions fixed before approval.
- [ ] Concurrent requests for one environment execute serially and remain restart-safe.
- [ ] A bounded Req health check distinguishes deployment success from verification failure.
- [ ] Tests prove path confinement, argument-safe Ansible invocation, secret non-persistence, log redaction, authorization, audit coverage, cancellation, and recovery after restart or runner loss.
- [ ] The repository and deployment LiveViews provide accessible status, approval, cancellation, redeploy, and retry-verification journeys.

## Open questions

None blocking. The first adapter targets GitHub-hosted recipe repositories and the existing Docker and remote runner protocol; provider-neutral recipe access follows the source-control port already established by SCM-001.

## Out of scope / future work

- Dynamic inventory plugins and inventory editing.
- Multi-stage approval policies and deployment windows.
- Automatic rollback policies.
- Deployment annotations in third-party monitoring systems.
- Kubernetes, Terraform, and other deployment executors.
- Ephemeral preview environments.
