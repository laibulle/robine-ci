# Robine CI

[![build](https://ci.base59.dev/badges/github/laibulle/robine-ci/build.svg)](https://ci.base59.dev/repositories)
[![coverage](https://ci.base59.dev/badges/github/laibulle/robine-ci/coverage.svg)](https://ci.base59.dev/repositories)

Robine CI is an open-source, self-hosted continuous integration service built with Elixir and Phoenix. It targets explicitly trusted GitHub repositories and executes jobs in isolated local or outbound-only remote Docker runners.

The project is under active development. The product contract is documented in [the specification index](docs/specs/README.md), implementation work is tracked in [TASKS.md](TASKS.md), and contributors must follow [AGENTS.md](AGENTS.md).

## Current implementation

- Phoenix 1.8 application with LiveView and Tailwind
- PostgreSQL persistence through Ecto
- Oban durable-work foundation
- Clean Architecture reference slice for pipeline creation
- Atomic pipeline and outbox persistence
- Workflow schema v1 parsing, semantic validation, and exact-revision reusable workflows
- Deterministic `success`, `failure`, and `always` conditions plus bounded static job matrices
- Stable workflow diagnostic codes and dependency-cycle detection
- Isolated local/remote Docker execution, attempt-private service containers, and the `robine` validation/execution CLI
- Encrypted secrets, immutable artifacts, local or S3-compatible caches/artifacts, and cursor-based redacted logs
- Authenticated GitHub webhooks, exact-SHA workflows, and durable check projection
- Local Argon2id authentication, revocable sessions, and optional OpenID Connect SSO
- Authenticated LiveView pipeline, job, log, cancellation, and retry experiences
- Outbound-only remote Docker runners with versioned restart-safe sessions and fleet administration

Untrusted-workload isolation remains post-MVP. Release validation that requires a real GitHub installation or external first-use participants remains tracked in `TASKS.md`.

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

Compose and Ecto share the `ROBINE_DEV_DATABASE_USER`, `ROBINE_DEV_DATABASE_PASSWORD`,
`ROBINE_DEV_DATABASE_NAME`, and `ROBINE_DEV_DATABASE_PORT` variables, with the local defaults
`postgres`, `postgres`, `robine_dev`, and `5432`. The authenticated healthcheck fails when a
persistent volume contains different credentials instead of reporting a false healthy state.

If an existing development volume has a stale password, repair the role through PostgreSQL's local
socket without deleting databases:

```bash
docker compose exec postgres \
  psql --username postgres --dbname postgres \
  --command="ALTER ROLE postgres WITH PASSWORD 'postgres'"
docker compose up -d --wait postgres
```

When overriding the development user or password, use the configured values in the repair command.
Reserve `docker compose down -v` for cases where losing all local development data is intentional.

Configure the mandatory secret-encryption master key for the server process:

```bash
export ROBINE_CI_SECRET_KEY="$(openssl rand -base64 32)"
export ROBINE_BOOTSTRAP_TOKEN="$(openssl rand -hex 24)"
```

Keep this key outside PostgreSQL and back it up securely. Losing it makes stored secrets unrecoverable.

For key rotation, configure all retained versions as a JSON object and select the new current version:

```bash
export ROBINE_CI_SECRET_KEYS='{"1":"<old-base64-key>","2":"<new-base64-key>"}'
export ROBINE_CI_SECRET_KEY_VERSION="2"
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

Run the complete test suite with local coverage enforcement:

```bash
mix coverage
```

The command fails below 75% total coverage and writes the browsable report to
`cover/excoveralls.html`. The self-hosted workflow runs the same command, retains `cover/` as the
`coverage-report` artifact for 14 days, and publishes the measured percentage, threshold, and a
direct authenticated download link in the provider pipeline and job checks. A stable SVG badge is
available at `/badges/:provider/:owner/:repository/coverage.svg`; it exposes only the latest retained
percentage. The metric covers application code; test-support fixtures and release-oriented Mix tasks
are excluded. Jobs never receive a provider token for this projection.

Open [http://localhost:4004](http://localhost:4004).

For development, visit `/setup` and use `development-bootstrap-token` unless `ROBINE_BOOTSTRAP_TOKEN` was provided. Production requires a fresh token at startup; it expires after 15 minutes and cannot be reused after the first account is created.

Retention cleanup runs hourly and can also be triggered by an administrator. Logs default to 30 days; expired artifact and cache metadata follows each object's declared expiry, while unreferenced content-addressed blobs have a one-hour safety grace. Override these bounded cleanup settings with `ROBINE_LOG_RETENTION_SECONDS`, `ROBINE_GC_GRACE_SECONDS`, and `ROBINE_RETENTION_BATCH_SIZE`.

The event outbox is reconciled every minute. Delivery retries use bounded exponential backoff, and authenticated instance health reports pending, stale, and dead-letter events.

## Publishing a GitHub release

Push a semantic version tag matching the version in `mix.exs`:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The tag-only `Robine Release` workflow builds the production OTP server, CLI, and standalone runner,
retains them as three independent `github-release` artifacts, then creates the matching GitHub Release
with generated notes and attaches stable `robine-server-<os>-<architecture>.tar.gz`,
`robine-cli-<os>-<architecture>.tar.gz`, and `robine-runner-<os>-<architecture>.tar.gz` assets. The
release tag already carries the version, so the filenames deliberately do not repeat it. The GitHub App
requires `Contents: read and write`; approve that updated permission on the installation before
pushing the tag. Release publication is idempotent and provider credentials remain in the control
plane.

Set `ROBINE_METRICS_TOKEN` to enable the token-protected Prometheus endpoint at `/metrics`; leave it unset to return 404. Initial alerts and diagnosis procedures are in [the monitoring runbook](docs/operations/monitoring-and-troubleshooting.md).

Artifact and cache metadata is admitted atomically against logical quotas of 50 GiB per instance and 10 GiB per repository. Override them with `ROBINE_STORAGE_INSTANCE_QUOTA_BYTES` and `ROBINE_STORAGE_REPOSITORY_QUOTA_BYTES`; the repository value cannot exceed the instance value.

Workflow validation defaults to 256 KiB, 64 jobs, 128 steps per job, 512 total steps, and DAG depth 16. Production deployments can override these with the `ROBINE_WORKFLOW_MAX_*` environment variables documented in [WF-001](docs/specs/workflows/wf-001-workflow-format.md).

Runner admission requires at least 2 GiB free and at most 95% filesystem usage by default. Configure `ROBINE_RUNNER_MIN_FREE_BYTES` and `ROBINE_RUNNER_MAX_USED_PERCENT` for the host. Robine reconciles only Docker resources carrying its `io.robine.attempt` label.

Each job is limited to 2 vCPU, 4 GiB RAM without additional swap, and 512 processes by default. Development uses 16 GiB RAM by default for the self-hosted CI workload. Configure `ROBINE_RUNNER_CPU_MILLIS`, `ROBINE_RUNNER_MEMORY_BYTES`, and `ROBINE_RUNNER_PIDS_LIMIT` to match the host.

Live cancellation polls durable state every 250 ms and gives the container five seconds to stop before Docker forces termination. Override the grace with `ROBINE_RUNNER_CANCELLATION_GRACE_MS`.

## Conditional cleanup and diagnostics

Use `if: failure` for diagnostics that should run only after an ordinary command or built-in failure, and `if: always` for cleanup that should run after success or ordinary failure:

```yaml
jobs:
  test:
    image: alpine:3.22
    steps:
      - name: Test
        run: ./test.sh
      - name: Upload diagnostics
        if: failure
        uses: artifacts/upload
        with:
          name: diagnostics
          paths: [tmp/diagnostics]
      - name: Cleanup
        if: always
        run: ./cleanup.sh
```

The only condition values are `success` (the default), `failure`, and `always`. Neither `failure` nor `always` continues after cancellation, timeout, runner loss, service loss, or an infrastructure error. `robine run` applies the same job and step rules as CI.

## Job matrices

Use a bounded static matrix to run one job across up to 32 Cartesian variants:

```yaml
jobs:
  test:
    strategy:
      matrix:
        elixir: ["1.18.4", "1.19.0"]
        otp: ["27.3", "28.0"]
    image: "hexpm/elixir:${{ matrix.elixir }}-erlang-${{ matrix.otp }}"
    steps:
      - run: mix test
```

Each variant receives `ROBINE_MATRIX_ELIXIR` and `ROBINE_MATRIX_OTP`, appears as an independent job and GitHub check, and can be reproduced exactly with a quoted generated key such as `robine run 'test[elixir=1.18.4,otp=27.3]'`. `robine run test` runs the whole group. Matrix expansion remains subject to the configured workflow job and step limits.

## Manual workflows

Declare bounded, non-secret inputs under `on.workflow_dispatch.inputs` to let administrators and maintainers launch a trusted repository workflow from its exact default-branch SHA:

```yaml
on:
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        required: true
        options: [staging, production]
      version:
        type: string
        required: true
      dry_run:
        type: boolean
        default: true
```

The normalized values are retained on the pipeline and injected as `ROBINE_INPUT_ENVIRONMENT`, `ROBINE_INPUT_VERSION`, and `ROBINE_INPUT_DRY_RUN`. They are deliberately visible and must never contain credentials. Reproduce the same run locally with repeated flags, for example `robine run release --input environment=staging --input version=2.4.0 --input dry_run=true`.

## Scheduled workflows

Robine evaluates native five-field cron expressions in UTC without calling a provider scheduler:

```yaml
on:
  schedule:
    - cron: "0 2 * * *"
    - cron: "*/30 9-17 * * 1-5"
```

Each due minute resolves the trusted repository's current default-branch head to an exact SHA and creates one idempotent pipeline. A durable cursor catches up missed occurrences for up to 24 hours after downtime; longer outages retain the newest 1,440 minutes and report the truncated backlog in metrics. Pipeline detail keeps the intended UTC occurrence separate from execution timestamps.

## Reusable workflows

Entry workflows can include reviewed jobs from another `.yml` file in the same repository and exact Git revision:

```yaml
includes:
  quality:
    path: .robine-ci/workflows/quality.yml
    inputs:
      runtime: "3.22"
jobs:
  package:
    image: alpine:3.22
    needs: quality--test
    steps: [{run: "true"}]
```

The included file declares `on.workflow_call.inputs`; its jobs are namespaced as `quality--<job>` and receive normalized non-secret values such as `ROBINE_CALL_INPUT_RUNTIME`. Composition is restricted to the same exact source set, four levels and 16 transitive includes. The CLI discovers these repository-local sources automatically, and immutable pipeline revisions retain every included source and digest. Cross-repository, URL, branch, tag, and secret call inputs are intentionally unsupported.

## GitHub App

Create a GitHub App for the instance with these repository permissions:

- Metadata: read
- Contents: read and write (required to publish tag releases and assets)
- Checks: read and write

Subscribe it to `push` and `pull_request`, set its webhook URL to `<ROBINE_PUBLIC_URL>/api/github/webhooks`, then configure:

```bash
export ROBINE_PUBLIC_URL="https://ci.example.com"
export GITHUB_APP_ID="123456"
export GITHUB_APP_PRIVATE_KEY="$(cat /secure/path/robine-app.pem)"
export GITHUB_WEBHOOK_SECRET="..."
```

`GITHUB_APP_PRIVATE_KEY` and `GITHUB_WEBHOOK_SECRET` are bootstrap and break-glass inputs. After the first administrator signs in, the Administration page can store replacements encrypted in PostgreSQL with the versioned instance AES-256-GCM key; encrypted values take precedence and are never displayed again. `GITHUB_APP_ID` remains non-secret configuration. Installation access tokens and their granted-permission projection are cached only until shortly before GitHub expires them.

## OpenID Connect

Register `<ROBINE_PUBLIC_URL>/auth/oidc/callback` as the exact redirect URI and configure one provider:

```bash
export OIDC_ISSUER="https://identity.example.com"
export OIDC_CLIENT_ID="robine"
export OIDC_CLIENT_SECRET="..."
```

OIDC uses Authorization Code with PKCE, state, nonce, issuer/audience/signature validation, and provider JWKS. New identities require a provider-verified email and start as viewers. Email collisions never auto-link accounts; local administrator sign-in remains available for recovery.

## Verification

CLI release bundles include `SHA256SUMS`. Build, platform verification, installation, and stable exit-code instructions are documented in [Install and verify the Robine CLI](docs/cli-installation.md).

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

Server installation, operational recovery, and limitations are documented in [installation](docs/operations/installation.md), [upgrade/backup/recovery](docs/operations/upgrade-backup-and-recovery.md), the [security model](docs/security-model.md), and [supported platforms](docs/operations/supported-platforms-and-limitations.md).

## License

Robine CI is distributed under AGPL-3.0-or-later. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).
