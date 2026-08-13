# Embedding the Robine CI backend

Robine CI can be consumed by another OTP application without sharing or starting any human UI.

## Dependency

Declare Robine without automatic application startup and supervise its backend explicitly:

```elixir
{:robine, git: "https://github.com/laibulle/robine-ci.git", runtime: false}
```

```elixir
children = [
  MyApp.Repo,
  {Robine.Runtime, profile: :embedded},
  MyAppWeb.Endpoint
]
```

Before building the supervision tree, configure the engine from the host repository:

```elixir
Robine.Runtime.configure_embedded!(
  repo_config: MyApp.Repo.config(),
  secret_key: Base.decode64!(System.fetch_env!("ROBINE_CI_SECRET_KEY")),
  runner_signing_secret: System.fetch_env!("ROBINE_CI_RUNNER_SIGNING_SECRET"),
  storage_root: "var/robine-ci",
  public_url: "https://workspace.example.com"
)
```

The host must configure `Robine.Repo` for the same PostgreSQL server, configure Oban with the `robine_ci` prefix, and provide Robine's operational secrets. Use a dedicated PostgreSQL application role without `SUPERUSER` or `BYPASSRLS`; embedded startup rejects unsafe roles.

## Migrations

Run versioned migrations directly from the dependency:

```console
mix robine.ci.migrate --repo MyApp.Repo
```

The default PostgreSQL prefix is `robine_ci`. It contains Robine tables and Oban tables, avoiding collisions with host tables such as `users`, `audit_events`, and `outbox_events`.

## Calls and authorization

The host translates its authenticated server-side scope into explicit CI capabilities. Host role names have no authority inside Robine.

```elixir
{:ok, context} =
  Robine.Runtime.Dependencies.embedded_context(
    %{id: user.id, role: membership.role},
    workspace.id,
    [:ci_run],
    request_id
  )

Robine.Backend.call(context, Robine.Pipelines, :list_pipelines, [%{limit: 50}])
```

Supported capabilities are `:ci_read`, `:ci_run`, `:ci_manage`, and `:ci_runner`. Database row-level security derives the tenant from the backend context; caller-provided query filters are never the isolation boundary.

## Events

An authenticated host may subscribe to a tenant-scoped backend topic:

```elixir
Robine.Backend.subscribe(context, "attempt-logs:" <> attempt_id)
```

Standalone Robine keeps its legacy topics for its existing UI. Embedded broadcasts are emitted only on tenant-prefixed topics.

Robine exports no LiveView, layout, navigation component, stylesheet, or JavaScript hook through this integration contract. The host owns the complete product experience.
