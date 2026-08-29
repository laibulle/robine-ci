# Server installation

## Supported host

Use a dedicated Ubuntu Server 24.04 or 26.04 LTS host with Docker Engine 29.x, Docker Compose v2, PostgreSQL 17 or 18, at least 4 CPU cores, 8 GiB RAM, and storage sized for the configured 50 GiB logical quota plus Docker images and workspaces. Robine's local Docker runner executes only trusted repository code; do not install it on a host shared with sensitive workloads.

## Ten-minute release installation

Before starting the measured installation, point the chosen DNS name at the host and allow inbound TCP 80/443 and UDP 443. Download the published server archive and its `SHA256SUMS`; image-download time may be recorded separately by the acceptance protocol.

Verify and start the complete PostgreSQL, Robine, and automatic-HTTPS stack:

```bash
sha256sum --check SHA256SUMS
tar -xzf robine-server-*.tar.gz
cd robine
./install.sh ci.example.com
```

The installer refuses to replace an existing `.env`, creates all instance and database secrets with mode `0600`, applies migrations, waits for readiness, and prints the one-use bootstrap token once. Open the printed `/setup` URL within 15 minutes. Back up `.env` through an encrypted channel before completing setup; losing `ROBINE_CI_SECRET_KEY` makes stored secrets unrecoverable.

The production Compose bundle pins PostgreSQL 18, the Ubuntu 24.04 or 26.04 runtime recorded by the target-specific release, and Caddy 2.10.2. Use an archive built for the host's exact supported Ubuntu version. Caddy obtains and renews HTTPS certificates automatically. A separate bundled `rbe` service enrolls itself through a private one-use handoff and provides the server's Linux Docker capacity through runner protocol v1. Only that runner service mounts the Docker socket; Phoenix has no Docker access. Use a dedicated host and never connect untrusted repositories.

Robine's native deployment workflow derives the same bundled runner companion automatically whenever
`ROBINE_BUNDLED_RUNNER_ENABLED` is enabled. It creates persistent runner-state and private bootstrap
volumes, mounts only the bootstrap volume into Phoenix, mounts the Docker socket only into the runner,
and reuses the promoted server release for the matching `rbe` binary. Repeated activation is idempotent;
explicitly disabling bundled capacity removes the companion but preserves its state volumes.

The runner identity appears as `robine-local` in Administration → Runners. Its credential is stored only in the private `runner_state` volume. If the identity is revoked, the runner discards that rejected credential, the server issues a new short-lived enrollment handoff, and the restarted sidecar enrolls a new ordinary runner identity. Set `ROBINE_BUNDLED_RUNNER_ENABLED=false` before startup to operate exclusively with separately enrolled runners; jobs remain queued when no compatible runner is online.

To inspect the generated configuration without starting services, use `./install.sh --prepare-only ci.example.com`. Delete the resulting `.env` before a real clean-room timing session.

## Manual configuration

For custom orchestration, create persistent PostgreSQL, blob-storage, runner-state, and runner-bootstrap volumes. Generate `SECRET_KEY_BASE`, a 32-byte base64 `ROBINE_CI_SECRET_KEY`, and a one-use random `ROBINE_BOOTSTRAP_TOKEN`. Configure `DATABASE_URL`, `ROBINE_PUBLIC_URL`, `PHX_HOST`, `PORT`, and `PHX_SERVER=true`. Run the bundled Linux `rbe` from the same release as a separate service, sharing only its bootstrap volume with Phoenix and mounting Docker only into the runner. Keep encryption keys outside the database and back them up separately.

Apply migrations before switching traffic:

```bash
bin/robine eval 'Robine.Runtime.Release.migrate()'
```

Start the release behind an HTTPS reverse proxy, then require HTTP 200 from `/health/live` and `/health/ready`. Visit `/setup` within 15 minutes and create the first administrator. Configure the GitHub App documented in the README, trust one exact repository through the UI, and add `.robine-ci/workflows/ci.yml` at the tested commit.

For Prometheus, set `ROBINE_METRICS_TOKEN` and scrape `/metrics` with a Bearer token. Leave it unset to disable export. Never expose Docker's socket, PostgreSQL, the metrics endpoint, or the Phoenix origin directly to the public internet.

## Optional S3-compatible blob storage

Local content-addressed storage remains the default. To place cache and artifact blobs in an existing private S3-compatible bucket, configure:

```bash
export ROBINE_BLOB_STORE="s3"
export ROBINE_S3_ENDPOINT="https://s3.eu-west-1.amazonaws.com"
export ROBINE_S3_REGION="eu-west-1"
export ROBINE_S3_BUCKET="robine-ci-production"
export ROBINE_S3_PREFIX="control-plane-1"
export ROBINE_S3_PATH_STYLE="false"
export ROBINE_STORAGE_ROOT="/var/lib/robine/storage"
```

Use the standard AWS credential environment or an automatically refreshed instance/container role. Prefer short-lived workload credentials; static `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_SESSION_TOKEN` are supported but should be rotated. Compatible providers that require path addressing use `ROBINE_S3_PATH_STYLE=true`. Plain HTTP is rejected except for an explicit loopback integration endpoint with `ROBINE_S3_ALLOW_HTTP_LOOPBACK=true`.

The role needs bucket listing plus get, put, delete, create/complete/abort multipart, and list-parts permissions limited to the configured bucket and prefix. When KMS encryption is configured at the bucket, grant only the corresponding data-key and decrypt permissions. Robine never gives bucket credentials to runners; transfers remain attempt-scoped through the control plane.

S3 uploads first use a bounded private spool below `ROBINE_STORAGE_ROOT/.s3-spool` so the SHA-256 content key is known before publication. Size this local volume for the maximum concurrent upload envelope.

Changing `ROBINE_BLOB_STORE`, the local storage root, or the S3 endpoint/bucket/prefix changes the storage namespace. When retained artifact or cache metadata exists, Robine refuses to start instead of silently orphaning it. To migrate:

1. Stop job admission and take a consistent PostgreSQL, configuration, and blob backup.
2. Copy every content-addressed object to the new namespace and verify its SHA-256 key and byte count.
3. Start once with the new storage configuration. The startup error reports the exact transition token it expects.
4. Set `ROBINE_STORAGE_BACKEND_MIGRATION_ACK` to that token and start Robine. Verify readiness, inventory, one cache restore, and one artifact download.
5. Remove the acknowledgement variable after the successful start. Keep the old namespace until the rollback window closes.

The acknowledgement authorizes only that exact old/new namespace-digest pair; it neither copies nor validates objects. A rollback is another namespace transition and must restore PostgreSQL and blob data as one consistent unit. There is no built-in local-to-S3 migration command in this release.

## Source installation for contributors

Install the pinned Elixir/Erlang, Node.js, Docker, and PostgreSQL versions, then run:

```bash
docker compose up -d --wait postgres
mix setup
mix qa
mix phx.server
```

The application is ready only when the complete QA command passes. Dependency compiler warnings under newer toolchains are upstream notices; Robine's own compilation must remain warning-free.
