import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :robine, Robine.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "robine_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :robine, Oban,
  testing: :manual,
  queues: false,
  plugins: false,
  peer: false

config :robine, :secret_keyring,
  current_version: 1,
  keys: %{1 => :binary.copy(<<42>>, 32)}

config :robine, :github_webhook_secret, "test-github-webhook-secret"
config :robine, :bootstrap_token_hash, :crypto.hash(:sha256, "test-bootstrap-token")
config :robine, :bootstrap_expires_at, ~U[2030-01-01 00:00:00Z]

config :argon2_elixir, t_cost: 1, m_cost: 8

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :robine, RobineWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "rGk+eq+m5/w/dODF8s/DmNbIvn7n8lMqhV9QbJmErsPo8AkuynSA3cvN0/DsUkvp",
  server: false

# In test we don't send emails
config :robine, Robine.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
