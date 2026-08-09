# Robine CI

Robine CI is an open-source, self-hosted continuous integration service built with Elixir and Phoenix. The MVP targets trusted GitHub repositories and executes jobs in local Docker containers.

The project is under active development. The product contract is documented in [the specification index](docs/specs/README.md), implementation work is tracked in [TASKS.md](TASKS.md), and contributors must follow [AGENTS.md](AGENTS.md).

## Current implementation

- Phoenix 1.8 application with LiveView and Tailwind
- PostgreSQL persistence through Ecto
- Oban durable-work foundation
- Clean Architecture reference slice for pipeline creation
- Atomic pipeline and outbox persistence
- Workflow schema v1 parsing and semantic validation
- Stable workflow diagnostic codes and dependency-cycle detection
- Isolated local Docker execution and the `robine` validation/execution CLI
- Encrypted secrets, immutable artifacts, caches, and cursor-based redacted logs
- Signed GitHub webhook ingestion, exact-SHA workflows, GitHub App installation tokens, and checks
- Local Argon2id authentication, revocable sessions, and optional OpenID Connect SSO
- Authenticated LiveView pipeline, job, log, cancellation, and retry experiences

Remote runners, storage quotas, archive hardening, and release hardening remain in progress; see `TASKS.md` for the authoritative status.

## Requirements

- Elixir 1.20 and Erlang/OTP 29
- Ubuntu Server 24.04 LTS or 26.04 LTS on x86-64 or ARM64
- Docker Engine 29.x
- Docker Compose v2
- Node.js 24 for asset development

These are the initial supported MVP versions.

## Local setup

Start PostgreSQL:

```bash
docker compose up -d --wait postgres
```

Configure the mandatory secret-encryption master key for the server process:

```bash
export ROBINE_SECRET_KEY="$(openssl rand -base64 32)"
export ROBINE_BOOTSTRAP_TOKEN="$(openssl rand -hex 24)"
```

Keep this key outside PostgreSQL and back it up securely. Losing it makes stored secrets unrecoverable.

For key rotation, configure all retained versions as a JSON object and select the new current version:

```bash
export ROBINE_SECRET_KEYS='{"1":"<old-base64-key>","2":"<new-base64-key>"}'
export ROBINE_SECRET_KEY_VERSION="2"
```

Restart Robine, then run bounded rotation batches from Instance Administration. Keep old keys configured until the UI reports completion and a backup has been verified.

Install dependencies, create the database, and build assets:

```bash
mix setup
```

Start Phoenix:

```bash
mix phx.server
```

Open [http://localhost:4000](http://localhost:4000).

For development, visit `/setup` and use `development-bootstrap-token` unless `ROBINE_BOOTSTRAP_TOKEN` was provided. Production requires a fresh token at startup; it expires after 15 minutes and cannot be reused after the first account is created.

Retention cleanup runs hourly and can also be triggered by an administrator. Logs default to 30 days; expired artifact and cache metadata follows each object's declared expiry, while unreferenced content-addressed blobs have a one-hour safety grace. Override these bounded cleanup settings with `ROBINE_LOG_RETENTION_SECONDS`, `ROBINE_GC_GRACE_SECONDS`, and `ROBINE_RETENTION_BATCH_SIZE`.

The event outbox is reconciled every minute. Delivery retries use bounded exponential backoff, and authenticated instance health reports pending, stale, and dead-letter events.

Artifact and cache metadata is admitted atomically against logical quotas of 50 GiB per instance and 10 GiB per repository. Override them with `ROBINE_STORAGE_INSTANCE_QUOTA_BYTES` and `ROBINE_STORAGE_REPOSITORY_QUOTA_BYTES`; the repository value cannot exceed the instance value.

Workflow validation defaults to 256 KiB, 64 jobs, 128 steps per job, 512 total steps, and DAG depth 16. Production deployments can override these with the `ROBINE_WORKFLOW_MAX_*` environment variables documented in [WF-001](docs/specs/workflows/wf-001-workflow-format.md).

Runner admission requires at least 2 GiB free and at most 95% filesystem usage by default. Configure `ROBINE_RUNNER_MIN_FREE_BYTES` and `ROBINE_RUNNER_MAX_USED_PERCENT` for the host. Robine reconciles only Docker resources carrying its `io.robine.attempt` label.

Each job is limited to 2 vCPU, 4 GiB RAM without additional swap, and 512 processes by default. Configure `ROBINE_RUNNER_CPU_MILLIS`, `ROBINE_RUNNER_MEMORY_BYTES`, and `ROBINE_RUNNER_PIDS_LIMIT` to match the host.

Live cancellation polls durable state every 250 ms and gives the container five seconds to stop before Docker forces termination. Override the grace with `ROBINE_RUNNER_CANCELLATION_GRACE_MS`.

## GitHub App

Create a GitHub App for the instance with these repository permissions:

- Metadata: read
- Contents: read
- Checks: read and write

Subscribe it to `push` and `pull_request`, set its webhook URL to `<ROBINE_PUBLIC_URL>/api/github/webhooks`, then configure:

```bash
export ROBINE_PUBLIC_URL="https://ci.example.com"
export GITHUB_APP_ID="123456"
export GITHUB_APP_PRIVATE_KEY="$(cat /secure/path/robine-app.pem)"
export GITHUB_WEBHOOK_SECRET="..."
```

The private key and webhook secret stay outside PostgreSQL. Installation access tokens are short-lived and cached only until shortly before GitHub expires them.

## OpenID Connect

Register `<ROBINE_PUBLIC_URL>/auth/oidc/callback` as the exact redirect URI and configure one provider:

```bash
export OIDC_ISSUER="https://identity.example.com"
export OIDC_CLIENT_ID="robine"
export OIDC_CLIENT_SECRET="..."
```

OIDC uses Authorization Code with PKCE, state, nonce, issuer/audience/signature validation, and provider JWKS. New identities require a provider-verified email and start as viewers. Email collisions never auto-link accounts; local administrator sign-in remains available for recovery.

## Verification

With PostgreSQL running:

```bash
mix verify
```

The verification alias checks formatting, compiles with warnings as errors, and runs the complete test suite.

## Architecture

Each bounded context exposes one facade such as `Robine.Pipelines`. Public operations delegate explicitly to use cases. Use cases coordinate pure domain rules and context-owned ports. PostgreSQL, Docker, GitHub, filesystem, Phoenix, LiveView, and Oban remain adapters around the application.

See [PLAT-002](docs/specs/platform/plat-002-clean-application-architecture.md) for the normative architecture.

## Security model

The MVP is for trusted repository code. Docker containers are not treated as a security boundary against hostile workloads. Do not connect untrusted public repositories or enable fork execution.

## License

Robine CI is distributed under AGPL-3.0-or-later. See [LICENSE](LICENSE).
