# Server installation

## Supported host

Use a dedicated Ubuntu Server 24.04 or 26.04 LTS host with Docker Engine 29.x, Docker Compose v2, PostgreSQL 17 or 18, at least 4 CPU cores, 8 GiB RAM, and storage sized for the configured 50 GiB logical quota plus Docker images and workspaces. Robine's local Docker runner executes only trusted repository code; do not install it on a host shared with sensitive workloads.

## Required configuration

Create persistent PostgreSQL and blob-storage volumes. Generate `SECRET_KEY_BASE` with `mix phx.gen.secret`, a 32-byte base64 `ROBINE_CI_SECRET_KEY`, and a one-use random `ROBINE_BOOTSTRAP_TOKEN`. Configure `DATABASE_URL`, `ROBINE_PUBLIC_URL`, `PHX_HOST`, `PORT`, and `PHX_SERVER=true`. Keep encryption keys outside the database and back them up separately.

Apply migrations before switching traffic:

```bash
bin/robine eval 'Robine.Runtime.Release.migrate()'
```

Start the release behind an HTTPS reverse proxy, then require HTTP 200 from `/health/live` and `/health/ready`. Visit `/setup` within 15 minutes and create the first administrator. Configure the GitHub App using the permissions in the README, trust one exact repository through the UI, and add `.robine-ci/workflows/ci.yml` at the tested commit.

For Prometheus, set `ROBINE_METRICS_TOKEN` and scrape `/metrics` with a Bearer token. Leave it unset to disable export. Never expose Docker's socket, PostgreSQL, the metrics endpoint, or the Phoenix origin directly to the public internet.

## Source installation for contributors

Install the pinned Elixir/Erlang, Node.js, Docker, and PostgreSQL versions, then run:

```bash
docker compose up -d --wait postgres
mix setup
mix qa
mix phx.server
```

The application is ready only when the complete QA command passes. Dependency compiler warnings under newer toolchains are upstream notices; Robine's own compilation must remain warning-free.
