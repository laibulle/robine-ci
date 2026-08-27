# DEP-001 — Native deployments

## Status

- **State:** Accepted
- **Owner:** Robine maintainers
- **Target:** Post-MVP
- **Last updated:** 2026-08-27

## Summary

Robine promotes an immutable artifact from a successful pipeline into a declared single-host Docker environment, converges its persistent services through a deployment-capable runner, retains a secret-safe audit trail, and verifies the exact deployed version before declaring success.

## Problem

Robine can build, retain, and publish immutable release artifacts but cannot deploy them without a separate orchestration repository. Operators need one controlled path from an exact successful revision to staging and production without installing Ansible, exposing an unrestricted Docker socket to CI jobs, rebuilding between environments, or losing the state of PostgreSQL, S3-compatible storage, and ingress services during an application promotion.

## Goals

- Promote the same digest from staging to production without rebuilding it.
- Manage the bounded Docker runtime needed by Robine applications, including persistent PostgreSQL, S3-compatible storage, and ingress services.
- Keep persistent-service changes independent from ordinary application releases.
- Survive control-plane restart, runner disconnect, and partially completed Docker operations through durable reconciliation.
- Reuse runner authentication, artifact transfer, secret redaction, live logs, cancellation, audit, and health verification.

## Non-goals

- General-purpose host provisioning, configuration management, or arbitrary Docker Compose execution.
- Installing Docker, creating operating-system users, configuring firewalls, disks, DNS, or TLS authority credentials.
- Running user-provided shell, SSH, Ansible, Terraform, Kubernetes, or arbitrary Docker API operations.
- Automatically reversing database migrations or inferring rollback safety.
- Treating containers or a mounted Docker socket as a security boundary for untrusted repositories.

## Users and use cases

### Primary user

A self-hosting administrator who has prepared a Linux Docker host and enrolled a dedicated deployment runner.

### Use cases

1. An administrator configures staging or protected production for one trusted repository.
2. The administrator declares pinned persistent services, named volumes, secret references, and an application service template.
3. A maintainer promotes a retained server artifact from a successful semantic-version tag pipeline to staging.
4. A different administrator approves promotion of the same digest to production.
5. Robine converges only changed services, migrates and activates the application, and verifies its health and reported version.
6. An operator observes or reconciles a deployment interrupted by control-plane or runner restart.
7. An operator explicitly promotes a previously deployed digest as an application rollback when migration policy permits it.

## Requirements

### Functional requirements

- **FR-1:** An environment MUST belong to one trusted application repository and define a unique lowercase name, protection mode, deployment-runner labels, deployment root, network name, timeout, and verification policy.
- **FR-2:** The initial implementation MUST support Linux single-host Docker environments through a separately enrolled runner advertising the `deployments` capability. Ordinary CI runners and jobs MUST NOT receive deployment authority or the host Docker socket.
- **FR-3:** An environment MUST declare one application service and MAY declare bounded persistent services. The initial supported persistent roles are PostgreSQL, S3-compatible object storage, and ingress; each role MUST have at most one service.
- **FR-4:** Every container image MUST use an immutable digest. Container names, network names, volume names, environment keys, container paths, health checks, commands, and resource limits MUST pass bounded allowlists and normalization.
- **FR-5:** Persistent volumes MUST be named, environment-owned, mounted only at absolute container paths, and MUST NOT be deleted by create, update, deploy, rollback, cancellation, or reconciliation operations.
- **FR-6:** Plaintext secret values MUST NOT appear in environment configuration. Container environment MAY reference context-owned secret names resolved only for the assigned deployment attempt.
- **FR-7:** Application deployment MUST consume a retained artifact from a successful tag pipeline for the same repository and exact commit. The deployment snapshot MUST record artifact ID, filename, SHA-256 digest, byte size, tag, commit, and pipeline.
- **FR-8:** Repeating a request for the same environment and artifact digest MUST be idempotent while an equivalent non-terminal or successful deployment exists. An artifact identity MUST NOT be mutable after request.
- **FR-9:** Staging MAY queue immediately for a maintainer. Protected production MUST require approval from an administrator other than the requester after the full immutable snapshot is created.
- **FR-10:** A deployment MUST transition through `requested`, optionally `awaiting_approval`, `queued`, `preparing`, `converging_services`, `migrating`, `activating`, `verifying`, and one terminal state of `succeeded`, `failed`, `cancelled`, or `verification_failed`. Invalid transitions MUST be rejected by the pure domain.
- **FR-11:** Only one deployment MAY be active per environment. Additional approved deployments MUST remain queued in request order.
- **FR-12:** Persistent services MUST be converged independently. An application-only promotion MUST NOT recreate or restart a healthy service whose normalized desired specification digest matches the retained observed digest.
- **FR-13:** Platform changes affecting persistent image digests, volume mounts, or database major versions MUST require a distinct administrator-approved platform deployment. A database major-version downgrade MUST be rejected.
- **FR-14:** Before a PostgreSQL major-version change, Robine MUST require recorded successful backup evidence produced within the configured freshness window. Robine MUST NOT claim that a container volume snapshot is a database-consistent backup.
- **FR-15:** The deployment runner MUST download the exact artifact through an authenticated attempt-scoped URL, verify its SHA-256 digest before extraction, use safe archive extraction, and never substitute a local build or mutable tag.
- **FR-16:** Application releases MUST be extracted below an environment-owned release directory keyed by digest. Activation MUST use an atomically replaced `current` link or an equivalently atomic adapter operation. At least the current and previous successful releases MUST be retained.
- **FR-17:** Database migrations MUST run through the packaged release command before activation. Migration execution MUST be recorded. Failed or unknown migration outcomes MUST prevent automatic activation.
- **FR-18:** Migration policy MUST be snapshotted as `application_only`, `forward_only`, or `rollback_safe`. Automatic downgrade is forbidden. An explicit rollback after a `forward_only` migration MUST be rejected unless an administrator records an external recovery decision.
- **FR-19:** After activation, Robine MUST perform a bounded same-origin HTTP verification with `Req`, default expected status 200–299, and MUST compare a configured response version with the requested release when version verification is enabled.
- **FR-20:** Rollback MUST create a new deployment pointing to a previously retained exact digest. It MUST pass the same approval, activation, audit, serialization, and verification rules as an ordinary deployment.
- **FR-21:** Cancellation MUST stop pending work and request runner cancellation, but MUST NOT delete persistent volumes or claim remote effects were reversed.
- **FR-22:** On reconnect or lease expiry, Robine MUST inspect labeled Docker resources and release activation state before deciding whether to resume, verify, or fail. It MUST NOT blindly replay a non-idempotent migration.

### UX requirements

- **UX-1:** A repository deployment page MUST show environments, current artifact digest and version, persistent-service health, active deployment, and last verification.
- **UX-2:** Environment configuration MUST distinguish application promotion settings from platform-service changes and explain that volumes are never removed automatically.
- **UX-3:** A deployment request and approval MUST show repository, commit, tag, artifact filename and digest, target environment, service changes, migration policy, and verification URL.
- **UX-4:** Production approval MUST be a separate explicit action and MUST reject self-approval.
- **UX-5:** The deployment timeline MUST distinguish artifact preparation, service convergence, migration, activation, and verification with retained redacted logs.
- **UX-6:** Failures MUST distinguish artifact integrity, capacity, Docker convergence, service readiness, migration, activation, runner loss, cancellation, and post-deployment verification.
- **UX-7:** Redeploy, explicit rollback, cancellation, retry verification, and reconcile actions MUST expose disabled and loading states and prevent duplicate submission.

### Operational requirements

- **OR-1:** Deployment authority MUST be a separate runner capability and scheduling pool with independent concurrency and timeout limits.
- **OR-2:** The runner MUST enforce an administrator-configured allowlist of environment IDs, host paths, service names, networks, volumes, and deployment operations before touching Docker.
- **OR-3:** Every Docker resource MUST carry bounded Robine instance, tenant, environment, service-role, and desired-specification-digest labels. Reconciliation MUST ignore unlabeled resources and resources owned by another instance or tenant.
- **OR-4:** Environment snapshots, deployments, transitions, approvals, platform changes, secret access, cancellations, reconciliation decisions, and verification results MUST be durable and tenant-isolated.
- **OR-5:** Secret values, authenticated artifact URLs, Docker registry credentials, database URLs, host addresses marked secret, and generated paths MUST NOT be persisted or emitted in logs.
- **OR-6:** The runner MUST continue an accepted deployment operation independently during a temporary control-plane restart and deliver ordered idempotent events after reconnect.
- **OR-7:** External effects MUST occur outside database transactions. Durable intents and idempotency keys MUST be committed before dispatch; observed effects MUST be projected afterward.
- **OR-8:** Artifact download, expanded archive size, file count, Docker pull, service readiness, migration, activation, verification, log output, and total deployment duration MUST be bounded.
- **OR-9:** Delivery code MUST call `Robine.Deployments`; domain and use-case modules MUST not depend on Phoenix, Ecto, Docker, Req, filesystems, or concrete adapters.

## Proposed design

`Robine.Deployments` is a bounded context containing pure `Environment`, `ServiceSpec`, `ArtifactSnapshot`, `Deployment`, and transition-policy modules. Use cases authorize configuration, snapshot exact artifacts, request and approve promotions, claim work, record ordered runner events, cancel, retry verification, and reconcile unknown outcomes. Context-owned ports cover persistence, artifact resolution, runner dispatch, secret resolution, remote observation, verification, clock, and identifiers. Concrete Ecto, storage-facade, runner-channel, Docker, archive, and Req implementations live under `Robine.Adapters` and are assembled only by `Robine.Runtime.Dependencies`.

The deployment runner advertises `"deployments" => true` in protocol capabilities and receives a distinct deployment offer, never a CI job specification. The offer contains a normalized desired-state document and authenticated URLs, not arbitrary shell. The runner validates the offer again against its local policy, downloads and verifies the release, converges the environment network and persistent services by normalized spec digest, executes the packaged migration through an argument vector, activates the release atomically, and emits ordered phase events. Docker operations use explicit executable arguments without `sh -c`.

Persistent services and the application have separate desired digests. A normal application promotion observes persistent services and refuses to proceed when they are missing or unhealthy; it does not mutate them. A platform deployment converges declared service changes under an additional approval and backup gate. Named volumes are create-only from Robine's perspective.

The deployment lifecycle is durable in PostgreSQL. Each event uses a deployment ID, attempt ID, idempotency token, monotonic sequence, phase, outcome, and safe diagnostic code. If the control plane restarts, the runner continues and resends unacknowledged events. If the runner restarts, reconciliation compares labels, container health, release directories, the `current` link, and the application's reported version. Unknown migration outcomes are terminal and require operator assessment rather than replay.

The first runtime strategy is a packaged OTP release mounted into a pinned runtime container alongside pinned PostgreSQL, optional S3-compatible storage, and pinned ingress containers on an environment-private Docker network. Supporting an application OCI image later requires another strategy, not arbitrary Compose fields.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Artifact missing or expired | Request is rejected before approval | Rebuild the exact tag or restore retained content |
| Artifact digest mismatch | Attempt fails before extraction or Docker mutation | Investigate storage integrity and request a new deployment |
| No deployment-capable runner | Deployment remains queued with capacity explanation | Restore or enroll an allowed deployment runner |
| Persistent service unhealthy | Application promotion stops without recreating it | Repair or explicitly deploy the platform change |
| Docker pull or convergence fails | Deployment fails with the last observed service state | Restore registry/runtime and create or reconcile a deployment |
| Migration fails | Activation does not occur and outcome is retained | Fix forward and deploy a new artifact |
| Migration outcome is unknown | Deployment fails closed and replay is blocked | Inspect database and record an administrator recovery decision |
| Activation succeeds but verification fails | Deployment becomes `verification_failed`; active digest remains visible | Retry verification or explicitly promote a safe prior digest |
| Control plane restarts | Runner continues and buffers bounded ordered events | Events reconcile after reconnect |
| Runner is lost | Lease expires and remote observation determines safe next state | Resume a safe idempotent phase or require operator assessment |
| Cancellation races activation | First persisted terminal decision wins while actual state remains observable | Reconcile and explicitly deploy the intended digest |

## Security and privacy

Only trusted repositories and deployment-capable runners participate. Repository maintainers may request allowed staging promotions; administrators configure environments and platform services, approve production, record backup evidence, and resolve unknown migration outcomes. The requester cannot approve their own protected deployment. Deployment runners are trusted host agents and MUST be isolated from ordinary CI capacity. Secrets are referenced by name, resolved for one attempt, redacted before transport logging, and removed from attempt material after completion. Docker socket access remains local to the deployment runner. Paths and names are normalized and checked against both control-plane snapshots and runner-local policy.

## Observability

Robine emits bounded counters and distributions for requests, approvals, queue time, phase duration, service convergence, migration outcomes, activation, verification, cancellation, reconciliation, and terminal outcome. Metric labels are limited to protection mode, deployment kind, phase, outcome, service role, and verification class. Repository names, environment names, versions, digests, URLs, hosts, actors, errors, and log output are forbidden labels. Structured events correlate repository, pipeline, artifact, deployment, attempt, runner, and audit identifiers.

## Acceptance criteria

- [ ] A successful semantic-version tag artifact is promoted to staging and then production without changing its digest.
- [ ] A dedicated deployment runner converges a pinned PostgreSQL, S3-compatible storage, application, and ingress stack on a real Docker host.
- [ ] An application-only promotion leaves healthy persistent-service container identities and volumes unchanged.
- [ ] Production requires approval from an administrator other than the requester after the artifact and desired state are fixed.
- [ ] Tests prove digest validation, safe extraction, path and argument confinement, runner capability isolation, secret non-persistence, volume preservation, serialization, cancellation, and tenant isolation.
- [ ] A control-plane restart during deployment and runner reconnect converge to the observed exact release without duplicating a migration.
- [ ] Verification checks both bounded HTTP health and the expected deployed version.
- [ ] Platform deployment rejects PostgreSQL downgrade and requires fresh backup evidence before a major-version change.
- [ ] Explicit rollback reuses a retained digest and is blocked when the snapshotted migration policy is not rollback-safe.
- [ ] Repository LiveViews expose configuration, approval, timeline, service health, retry verification, reconciliation, and rollback journeys accessibly.

## Open questions

None blocking. The initial strategy is deliberately limited to a prepared Linux Docker host and packaged OTP releases. Persistent S3 may be an operator-managed remote endpoint or a declared local S3-compatible service; only the latter is converged by Robine.

## Out of scope / future work

- Host bootstrap and runner installation.
- Multi-host high availability, rolling deploys, canaries, and blue-green traffic management.
- Automatic database restore or migration reversal.
- General Docker Compose import and arbitrary container roles.
- OCI application releases, Kubernetes, Nomad, Terraform, Ansible, and SSH executors.
- Dynamic infrastructure provisioning, DNS, and certificate-authority management.
