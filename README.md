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

Runner execution, GitHub integration, authentication, secrets, caches, artifacts, the CLI, and the complete web interface are not implemented yet.

## Requirements

- Elixir 1.20 and Erlang/OTP 29
- Docker Engine 29 or compatible
- Docker Compose v2
- Node.js 24 for asset development

These versions describe the current development environment and are not a final support policy.

## Local setup

Start PostgreSQL:

```bash
docker compose up -d --wait postgres
```

Install dependencies, create the database, and build assets:

```bash
mix setup
```

Start Phoenix:

```bash
mix phx.server
```

Open [http://localhost:4000](http://localhost:4000).

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

