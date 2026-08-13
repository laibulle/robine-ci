# Robine CI specifications

Robine CI is an open-source, self-hosted continuous integration service for individual developers and startups. Its product promise is a delightful path from installation to diagnosis: a first pipeline in under ten minutes, reproducible local execution, precise configuration feedback, and clear real-time logs.

## Product decisions

- The server is built with Elixir, Phoenix LiveView, and Tailwind CSS.
- The MVP runs trusted repositories in local Docker containers.
- GitHub is the only source-code provider in the MVP.
- Workflows live under `.robine-ci/workflows/*.yml`.
- The CLI is a first-class product surface and uses the same execution semantics as CI.
- The complete self-hosted product, including SSO, is open source under AGPL-3.0-or-later.
- Revenue is expected from a managed cloud service and commercial support, not proprietary self-hosted features.

## Specification conventions

Feature specifications live at `docs/specs/<domain>/<FEAT-ID>-<feature-name>.md`. Feature IDs are stable and use an uppercase domain prefix. File names use the lowercase feature ID and kebab-case feature name. Specifications use the terms MUST, SHOULD, and MAY as defined by RFC 2119.

New specifications MUST start from [TEMPLATE.md](TEMPLATE.md). A feature is not ready for implementation until its state is `Accepted` and all blocking open questions are resolved.

## MVP specifications

| Domain | Specification | Purpose |
|---|---|---|
| Product | [PROD-001 MVP definition](product/prod-001-mvp-definition.md) | Product promise, scope, and success measures |
| Platform | [PLAT-001 system architecture](platform/plat-001-system-architecture.md) | Control-plane and runner boundaries |
| Platform | [PLAT-002 clean application architecture](platform/plat-002-clean-application-architecture.md) | Use cases, ports, adapters, facades, and dependency rules |
| Workflows | [WF-001 workflow format](workflows/wf-001-workflow-format.md) | YAML schema and execution graph |
| Execution | [EXEC-001 local Docker runner](execution/exec-001-local-docker-runner.md) | Container lifecycle and job semantics |
| CLI | [CLI-001 local developer experience](cli/cli-001-local-developer-experience.md) | Init, validation, and local execution |
| GitHub | [GH-001 GitHub integration](github/gh-001-github-integration.md) | App installation, webhooks, and checks |
| Web | [WEB-001 pipeline experience](web/web-001-pipeline-experience.md) | LiveView UI and real-time logs |
| Identity | [IAM-001 authentication and SSO](identity/iam-001-authentication-and-sso.md) | Local auth, OIDC, and authorization |
| Security | [SEC-001 secrets and trust model](security/sec-001-secrets-and-trust-model.md) | Encryption, masking, and trusted code policy |
| Storage | [DATA-001 cache and artifacts](storage/data-001-cache-and-artifacts.md) | Dependency cache and job outputs |
| Operations | [OPS-001 observability and health](operations/ops-001-observability-and-health.md) | Probes, dependency diagnostics, metrics, and alerts |

## Post-MVP specifications

| Domain | Specification | Purpose |
|---|---|---|
| Runners | [RUN-001 remote runner protocol](runners/run-001-remote-runner-protocol.md) | Enrollment, authentication, versioned delivery, and reconnection |
| Runners | [RUN-002 runner fleet and scheduling](runners/run-002-runner-fleet-and-scheduling.md) | Labels, capacity matching, lifecycle administration, and autoscaling boundary |
| Runners | [RUN-003 macOS native runner](runners/run-003-macos-native-runner.md) | Dedicated Darwin host execution for trusted Apple-platform CI |
| Storage | [DATA-002 S3-compatible blob storage](storage/data-002-s3-compatible-storage.md) | Provider-neutral object storage, multipart transfer, and reconciliation |
| Execution | [EXEC-002 service containers](execution/exec-002-service-containers.md) | Attempt-scoped Docker services, readiness, secrets, and cleanup |
| Workflows | [WF-002 conditional execution](workflows/wf-002-conditional-execution.md) | Fixed success, failure, and always job/step conditions |
| Workflows | [WF-003 job matrices](workflows/wf-003-job-matrices.md) | Bounded static Cartesian job expansion and local reproduction |
| Workflows | [WF-004 manual workflow inputs](workflows/wf-004-manual-workflow-inputs.md) | Exact-SHA manual launches with bounded typed inputs |
| Workflows | [WF-005 scheduled workflows](workflows/wf-005-scheduled-workflows.md) | Durable UTC cron scheduling with exact-SHA execution |
| Workflows | [WF-006 reusable workflows](workflows/wf-006-reusable-workflows.md) | Exact-revision local includes with typed call inputs |
| Source control | [SCM-001 GitLab and Forgejo integration](source-control/scm-001-gitlab-forgejo-integration.md) | Provider-neutral exact-SHA integration and status projection |
| Quality | [QUAL-001 coverage reporting](quality/qual-001-coverage-reporting.md) | Local coverage enforcement and future provider publication |
| Releases | [REL-002 GitHub tag releases](releases/rel-002-github-tag-releases.md) | Build and publish immutable GitHub release payloads from tags |
