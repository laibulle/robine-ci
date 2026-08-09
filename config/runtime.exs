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

storage_root = System.get_env("ROBINE_STORAGE_ROOT", "var/storage") |> Path.expand()
config :robine, :storage_root, storage_root

blob_store_adapter =
  case System.get_env("ROBINE_BLOB_STORE", "local") do
    "local" -> Robine.Adapters.Storage.LocalBlobStore
    "s3" -> Robine.Adapters.Storage.S3BlobStore
    _invalid -> raise "ROBINE_BLOB_STORE must be local or s3"
  end

config :robine, :blob_store_adapter, blob_store_adapter

config :robine,
       :storage_backend_migration_ack,
       System.get_env("ROBINE_STORAGE_BACKEND_MIGRATION_ACK")

if blob_store_adapter == Robine.Adapters.Storage.S3BlobStore do
  endpoint = System.fetch_env!("ROBINE_S3_ENDPOINT")
  bucket = System.fetch_env!("ROBINE_S3_BUCKET")
  region = System.fetch_env!("ROBINE_S3_REGION")
  prefix = System.get_env("ROBINE_S3_PREFIX", "")
  allow_http_loopback = System.get_env("ROBINE_S3_ALLOW_HTTP_LOOPBACK") in ~w(1 true)

  encryption =
    case {System.get_env("ROBINE_S3_KMS_KEY_ID"),
          System.get_env("ROBINE_S3_SERVER_SIDE_ENCRYPTION", "none")} do
      {key_id, _mode} when is_binary(key_id) and key_id != "" -> [aws_kms_key_id: key_id]
      {nil, "AES256"} -> "AES256"
      {nil, "none"} -> nil
      _invalid -> raise "ROBINE_S3_SERVER_SIDE_ENCRYPTION must be none or AES256"
    end

  config :robine, :s3_blob_store,
    client: Robine.Adapters.Storage.ExAwsS3Client,
    endpoint: endpoint,
    bucket: bucket,
    region: region,
    prefix: prefix,
    allow_http_loopback: allow_http_loopback,
    path_style: System.get_env("ROBINE_S3_PATH_STYLE") in ~w(1 true),
    encryption: encryption,
    spool_root: Path.join(storage_root, ".s3-spool"),
    part_size: positive_integer.("ROBINE_S3_PART_SIZE_BYTES", 8_388_608),
    multipart_concurrency: positive_integer.("ROBINE_S3_MULTIPART_CONCURRENCY", 2),
    part_timeout_ms: positive_integer.("ROBINE_S3_PART_TIMEOUT_MS", 60_000)
end

config :robine, :workflow_limits,
  max_source_bytes: positive_integer.("ROBINE_WORKFLOW_MAX_BYTES", 262_144),
  max_jobs: positive_integer.("ROBINE_WORKFLOW_MAX_JOBS", 64),
  max_steps_per_job: positive_integer.("ROBINE_WORKFLOW_MAX_STEPS_PER_JOB", 128),
  max_total_steps: positive_integer.("ROBINE_WORKFLOW_MAX_TOTAL_STEPS", 512),
  max_graph_depth: positive_integer.("ROBINE_WORKFLOW_MAX_GRAPH_DEPTH", 16)

runner_max_used_default =
  case config_env() do
    :prod -> 95
    :dev -> 98
    :test -> 100
  end

config :robine, :runner_admission,
  min_free_bytes: positive_integer.("ROBINE_RUNNER_MIN_FREE_BYTES", 2_147_483_648),
  max_used_percent: percentage.("ROBINE_RUNNER_MAX_USED_PERCENT", runner_max_used_default)

runner_memory_default =
  case config_env() do
    :dev -> 17_179_869_184
    _other -> 4_294_967_296
  end

config :robine, :runner_resources,
  cpu_millis: positive_integer.("ROBINE_RUNNER_CPU_MILLIS", 2_000),
  memory_bytes: positive_integer.("ROBINE_RUNNER_MEMORY_BYTES", runner_memory_default),
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

if encoded_keys = System.get_env("ROBINE_CI_SECRET_KEYS") do
  current_version = positive_integer.("ROBINE_CI_SECRET_KEY_VERSION", 1)

  keys =
    encoded_keys
    |> then(fn value ->
      case Jason.decode(value) do
        {:ok, decoded} when is_map(decoded) -> decoded
        _ -> raise "ROBINE_CI_SECRET_KEYS must be a JSON object of version-to-key entries"
      end
    end)
    |> Enum.map(fn {version, encoded} ->
      case Integer.parse(version) do
        {number, ""} when number > 0 and is_binary(encoded) ->
          {number, decode_secret_key.(encoded, "ROBINE_CI_SECRET_KEYS[#{version}]")}

        _ ->
          raise "ROBINE_CI_SECRET_KEYS versions must be positive integer strings"
      end
    end)
    |> Map.new()

  unless Map.has_key?(keys, current_version) do
    raise "ROBINE_CI_SECRET_KEYS must contain ROBINE_CI_SECRET_KEY_VERSION"
  end

  config :robine, :secret_keyring, current_version: current_version, keys: keys
else
  if encoded_key = System.get_env("ROBINE_CI_SECRET_KEY") do
    version = positive_integer.("ROBINE_CI_SECRET_KEY_VERSION", 1)

    config :robine, :secret_keyring,
      current_version: version,
      keys: %{version => decode_secret_key.(encoded_key, "ROBINE_CI_SECRET_KEY")}
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

source_control_url = fn name ->
  case System.get_env(name) do
    nil ->
      nil

    value ->
      uri = URI.parse(value)
      allow_http = config_env() in [:dev, :test] and uri.host in ["localhost", "127.0.0.1", "::1"]

      valid_scheme = uri.scheme == "https" or (uri.scheme == "http" and allow_http)

      if valid_scheme and is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and
           is_nil(uri.query) and is_nil(uri.fragment) and uri.path in [nil, "", "/"] do
        String.trim_trailing(value, "/")
      else
        raise "#{name} must be an HTTPS origin without credentials, path, query, or fragment"
      end
  end
end

config :robine, :gitlab_source_control,
  base_url: source_control_url.("GITLAB_URL"),
  http_client: Robine.Adapters.SourceControl.ReqHttpClient

config :robine, :forgejo_source_control,
  base_url: source_control_url.("FORGEJO_URL"),
  http_client: Robine.Adapters.SourceControl.ReqHttpClient

for {environment, key} <- [
      {"GITLAB_TOKEN", :gitlab_token},
      {"GITLAB_WEBHOOK_SECRET", :gitlab_webhook_secret},
      {"FORGEJO_TOKEN", :forgejo_token},
      {"FORGEJO_WEBHOOK_SECRET", :forgejo_webhook_secret}
    ],
    value = System.get_env(environment),
    is_binary(value) and value != "" do
  config :robine, key, value
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
    public_url = System.get_env("ROBINE_PUBLIC_URL", "http://localhost:4004")

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
  http: [port: String.to_integer(System.get_env("PORT", "4004"))]

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
