# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :robine,
  ecto_repos: [Robine.Repo],
  generators: [timestamp_type: :utc_datetime],
  storage_root: Path.expand("../var/storage", __DIR__),
  storage_max_object_bytes: 1_073_741_824,
  storage_quotas: [instance_bytes: 53_687_091_200, repository_bytes: 10_737_418_240],
  workflow_limits: [
    max_source_bytes: 262_144,
    max_jobs: 64,
    max_steps_per_job: 128,
    max_total_steps: 512,
    max_graph_depth: 16
  ],
  runner_admission: [min_free_bytes: 2_147_483_648, max_used_percent: 95],
  runner_resources: [cpu_millis: 2_000, memory_bytes: 4_294_967_296, pids_limit: 512],
  runner_control: [
    lease_seconds: 60,
    heartbeat_interval_ms: 20_000,
    cancellation_poll_interval_ms: 500
  ],
  runner_cancellation_grace_ms: 5_000,
  retention: [log_seconds: 2_592_000, gc_grace_seconds: 3_600, batch_size: 1_000],
  public_url: "http://localhost:4000",
  bootstrap_token_hash: :crypto.hash(:sha256, "development-bootstrap-token"),
  bootstrap_expires_at: ~U[2030-01-01 00:00:00Z],
  oidc_config: nil

config :robine, Oban,
  repo: Robine.Repo,
  queues: [default: 10, outbox: 5],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Robine.Adapters.Background.ReconcileLeasesWorker},
       {"*/5 * * * *", Robine.Adapters.Background.ReconcileGitHubChecksWorker},
       {"*/5 * * * *", Robine.Adapters.Background.ReconcileRunnerResourcesWorker},
       {"17 * * * *", Robine.Adapters.Background.PruneRetentionWorker}
     ]}
  ]

# Configure the endpoint
config :robine, RobineWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: RobineWeb.ErrorHTML, json: RobineWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Robine.PubSub,
  live_view: [signing_salt: "UTWjr2T8"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :robine, Robine.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  robine: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  robine: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
