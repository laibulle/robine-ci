import Config

positive_integer = fn name, default ->
  case Integer.parse(System.get_env(name, Integer.to_string(default))) do
    {value, ""} when value > 0 -> value
    _ -> raise "#{name} must be a positive integer"
  end
end

percentage = fn name, default ->
  case Integer.parse(System.get_env(name, Integer.to_string(default))) do
    {value, ""} when value in 1..100 -> value
    _ -> raise "#{name} must be an integer from 1 through 100"
  end
end

config :robine, :retention,
  log_seconds: positive_integer.("ROBINE_LOG_RETENTION_SECONDS", 2_592_000),
  gc_grace_seconds: positive_integer.("ROBINE_GC_GRACE_SECONDS", 3_600),
  batch_size: positive_integer.("ROBINE_RETENTION_BATCH_SIZE", 1_000)

storage_instance_quota = positive_integer.("ROBINE_STORAGE_INSTANCE_QUOTA_BYTES", 53_687_091_200)

storage_repository_quota =
  positive_integer.("ROBINE_STORAGE_REPOSITORY_QUOTA_BYTES", 10_737_418_240)

if storage_repository_quota > storage_instance_quota do
  raise "ROBINE_STORAGE_REPOSITORY_QUOTA_BYTES must not exceed the instance quota"
end

config :robine, :storage_quotas,
  instance_bytes: storage_instance_quota,
  repository_bytes: storage_repository_quota

config :robine, :workflow_limits,
  max_source_bytes: positive_integer.("ROBINE_WORKFLOW_MAX_BYTES", 262_144),
  max_jobs: positive_integer.("ROBINE_WORKFLOW_MAX_JOBS", 64),
  max_steps_per_job: positive_integer.("ROBINE_WORKFLOW_MAX_STEPS_PER_JOB", 128),
  max_total_steps: positive_integer.("ROBINE_WORKFLOW_MAX_TOTAL_STEPS", 512),
  max_graph_depth: positive_integer.("ROBINE_WORKFLOW_MAX_GRAPH_DEPTH", 16)

config :robine, :runner_admission,
  min_free_bytes: positive_integer.("ROBINE_RUNNER_MIN_FREE_BYTES", 2_147_483_648),
  max_used_percent: percentage.("ROBINE_RUNNER_MAX_USED_PERCENT", 95)

config :robine, :runner_resources,
  cpu_millis: positive_integer.("ROBINE_RUNNER_CPU_MILLIS", 2_000),
  memory_bytes: positive_integer.("ROBINE_RUNNER_MEMORY_BYTES", 4_294_967_296),
  pids_limit: positive_integer.("ROBINE_RUNNER_PIDS_LIMIT", 512)

config :robine, :runner_control,
  lease_seconds: positive_integer.("ROBINE_RUNNER_LEASE_SECONDS", 60),
  heartbeat_interval_ms: positive_integer.("ROBINE_RUNNER_HEARTBEAT_INTERVAL_MS", 20_000),
  cancellation_poll_interval_ms:
    positive_integer.("ROBINE_RUNNER_CANCELLATION_POLL_INTERVAL_MS", 500)

config :robine,
       :runner_cancellation_grace_ms,
       positive_integer.("ROBINE_RUNNER_CANCELLATION_GRACE_MS", 5_000)

decode_secret_key = fn encoded, label ->
  case Base.decode64(encoded) do
    {:ok, key} when byte_size(key) == 32 -> key
    _ -> raise "#{label} must contain a base64-encoded 32-byte key"
  end
end

if encoded_keys = System.get_env("ROBINE_SECRET_KEYS") do
  current_version = positive_integer.("ROBINE_SECRET_KEY_VERSION", 1)

  keys =
    encoded_keys
    |> then(fn value ->
      case Jason.decode(value) do
        {:ok, decoded} when is_map(decoded) -> decoded
        _ -> raise "ROBINE_SECRET_KEYS must be a JSON object of version-to-key entries"
      end
    end)
    |> Enum.map(fn {version, encoded} ->
      case Integer.parse(version) do
        {number, ""} when number > 0 and is_binary(encoded) ->
          {number, decode_secret_key.(encoded, "ROBINE_SECRET_KEYS[#{version}]")}

        _ ->
          raise "ROBINE_SECRET_KEYS versions must be positive integer strings"
      end
    end)
    |> Map.new()

  unless Map.has_key?(keys, current_version) do
    raise "ROBINE_SECRET_KEYS must contain ROBINE_SECRET_KEY_VERSION"
  end

  config :robine, :secret_keyring, current_version: current_version, keys: keys
else
  if encoded_key = System.get_env("ROBINE_SECRET_KEY") do
    version = positive_integer.("ROBINE_SECRET_KEY_VERSION", 1)

    config :robine, :secret_keyring,
      current_version: version,
      keys: %{version => decode_secret_key.(encoded_key, "ROBINE_SECRET_KEY")}
  end
end

if webhook_secret = System.get_env("GITHUB_WEBHOOK_SECRET") do
  config :robine, :github_webhook_secret, webhook_secret
end

if github_app_id = System.get_env("GITHUB_APP_ID") do
  config :robine, :github_app_id, github_app_id
end

if github_private_key = System.get_env("GITHUB_APP_PRIVATE_KEY") do
  config :robine, :github_app_private_key, String.replace(github_private_key, "\\n", "\n")
end

if bootstrap_token = System.get_env("ROBINE_BOOTSTRAP_TOKEN") do
  config :robine,
    bootstrap_token_hash: :crypto.hash(:sha256, bootstrap_token),
    bootstrap_expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
end

if metrics_token = System.get_env("ROBINE_METRICS_TOKEN") do
  config :robine, :metrics_token_hash, :crypto.hash(:sha256, metrics_token)
end

case {System.get_env("OIDC_ISSUER"), System.get_env("OIDC_CLIENT_ID"),
      System.get_env("OIDC_CLIENT_SECRET")} do
  {issuer, client_id, client_secret}
  when is_binary(issuer) and is_binary(client_id) and is_binary(client_secret) ->
    public_url = System.get_env("ROBINE_PUBLIC_URL", "http://localhost:4000")

    config :robine,
      public_url: public_url,
      oidc_config: [
        base_url: issuer,
        client_id: client_id,
        client_secret: client_secret,
        redirect_uri: public_url <> "/auth/oidc/callback",
        authorization_params: [scope: "openid email profile"],
        trusted_audiences: [client_id]
      ]

  _ ->
    :ok
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/robine start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :robine, RobineWeb.Endpoint, server: true
end

config :robine, RobineWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :robine, RobineWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/robine_web/router\.ex$"E,
        ~r"lib/robine_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  bootstrap_token =
    System.get_env("ROBINE_BOOTSTRAP_TOKEN") ||
      raise "environment variable ROBINE_BOOTSTRAP_TOKEN is missing"

  config :robine,
    bootstrap_token_hash: :crypto.hash(:sha256, bootstrap_token),
    bootstrap_expires_at: DateTime.add(DateTime.utc_now(), 900, :second)

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :robine, Robine.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :robine, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :robine, RobineWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :robine, RobineWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :robine, RobineWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :robine, Robine.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
