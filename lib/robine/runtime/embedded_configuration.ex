defmodule Robine.Runtime.EmbeddedConfiguration do
  @moduledoc "Configures a Robine backend runtime from an embedding host's repository."

  @spec configure!(keyword()) :: :ok
  def configure!(options) do
    repo_config = Keyword.fetch!(options, :repo_config)
    secret_key = Keyword.fetch!(options, :secret_key)
    signing_secret = Keyword.fetch!(options, :runner_signing_secret)
    prefix = Keyword.get(options, :prefix, Robine.Runtime.Metadata.default_prefix())

    unless is_binary(secret_key) and byte_size(secret_key) == 32,
      do: raise(ArgumentError, "embedded secret_key must contain exactly 32 bytes")

    unless is_binary(signing_secret) and byte_size(signing_secret) >= 32,
      do: raise(ArgumentError, "embedded runner_signing_secret must contain at least 32 bytes")

    Application.put_env(:robine, :runtime_profile, :embedded)
    Application.put_env(:robine, :database_prefix, prefix)
    Application.put_env(:robine, Robine.Repo, Keyword.delete(repo_config, :name))
    Application.put_env(:robine, :secret_keyring, %{current_version: 1, keys: %{1 => secret_key}})
    Application.put_env(:robine, RobineWeb.Endpoint, secret_key_base: signing_secret)

    put_defaults(options)
    configure_oban(prefix)
    :ok
  end

  defp put_defaults(options) do
    defaults = [
      blob_store_adapter: Robine.Adapters.Storage.LocalBlobStore,
      storage_backend_migration_ack: nil,
      s3_blob_store: nil,
      storage_root: Keyword.get(options, :storage_root, Path.expand("var/robine-ci")),
      storage_max_object_bytes: 1_073_741_824,
      storage_quotas: [instance_bytes: 53_687_091_200, repository_bytes: 10_737_418_240],
      transfer_limits: [max_archive_bytes: 268_435_456],
      workflow_limits: [
        max_source_bytes: 262_144,
        max_jobs: 64,
        max_steps_per_job: 128,
        max_total_steps: 512,
        max_graph_depth: 16
      ],
      runner_admission: [min_free_bytes: 2_147_483_648, max_used_percent: 95],
      runner_resource_namespace: "embedded",
      runner_resources: [cpu_millis: 2_000, memory_bytes: 4_294_967_296, pids_limit: 512],
      runner_control: [
        lease_seconds: 60,
        heartbeat_interval_ms: 20_000,
        cancellation_poll_interval_ms: 500
      ],
      runner_cancellation_grace_ms: 5_000,
      retention: [log_seconds: 2_592_000, gc_grace_seconds: 3_600, batch_size: 1_000],
      public_url: Keyword.get(options, :public_url, "http://localhost:4004"),
      github_adapter: Robine.Adapters.SourceControl.GitHubClient,
      gitlab_source_control: [base_url: nil],
      forgejo_source_control: [base_url: nil]
    ]

    Enum.each(defaults, fn {key, value} ->
      if is_nil(Application.get_env(:robine, key)), do: Application.put_env(:robine, key, value)
    end)
  end

  defp configure_oban(prefix) do
    Application.put_env(:robine, Oban,
      repo: Robine.Repo,
      prefix: prefix,
      queues: [default: 10, outbox: 5],
      plugins: [
        Oban.Plugins.Pruner,
        {Oban.Plugins.Cron,
         crontab: [
           {"* * * * *", Robine.Adapters.Background.ReconcileLeasesWorker},
           {"* * * * *", Robine.Adapters.Background.ReconcileOutboxWorker},
           {"* * * * *", Robine.Adapters.Background.ReconcileAutoscalingWorker},
           {"* * * * *", Robine.Adapters.Background.ReconcileScheduledWorkflowsWorker},
           {"*/5 * * * *", Robine.Adapters.Background.ReconcileGitHubChecksWorker},
           {"*/5 * * * *", Robine.Adapters.Background.ReconcileRunnerResourcesWorker},
           {"17 * * * *", Robine.Adapters.Background.PruneRetentionWorker}
         ]}
      ]
    )
  end
end
