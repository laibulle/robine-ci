defmodule Robine.Runtime.Dependencies do
  @moduledoc "The sole production composition root for application dependencies."

  alias Robine.ExecutionContext
  alias Robine.Autoscaling.Dependencies, as: AutoscalingDependencies
  alias Robine.Execution.Dependencies, as: ExecutionDependencies
  alias Robine.Identities.Dependencies, as: IdentityDependencies
  alias Robine.Operations.Dependencies, as: OperationsDependencies
  alias Robine.Pipelines.Dependencies, as: PipelineDependencies
  alias Robine.Repositories.Dependencies, as: RepositoryDependencies
  alias Robine.Runners.Dependencies, as: RunnerDependencies
  alias Robine.Secrets.Dependencies, as: SecretDependencies
  alias Robine.Storage.Dependencies, as: StorageDependencies
  alias Robine.Transfers.Dependencies, as: TransferDependencies
  alias Robine.Workflows.Dependencies, as: WorkflowDependencies

  @spec local_context() :: ExecutionContext.t()
  def local_context do
    ExecutionContext.new(%{id: "cli", role: :maintainer}, "cli", %{
      workflows: %WorkflowDependencies{decoder: Robine.Adapters.Workflow.YamlDecoder},
      execution: %ExecutionDependencies{runner: Robine.Adapters.Execution.DockerRunner}
    })
  end

  @spec context(ExecutionContext.actor(), String.t()) :: ExecutionContext.t()
  def context(actor, correlation_id) do
    storage_quotas = Application.fetch_env!(:robine, :storage_quotas)
    retention = Application.fetch_env!(:robine, :retention)
    blob_store = Application.fetch_env!(:robine, :blob_store_adapter)

    ExecutionContext.new(actor, correlation_id, %{
      pipelines: %PipelineDependencies{
        unit_of_work: Robine.Adapters.Persistence.Postgres.UnitOfWork,
        pipeline_repository: Robine.Adapters.Persistence.Postgres.PipelineRepository,
        job_repository: Robine.Adapters.Persistence.Postgres.JobRepository,
        log_repository: Robine.Adapters.Persistence.Postgres.LogRepository,
        admission: Robine.Adapters.System.DiskAdmission,
        event_outbox: Robine.Adapters.Persistence.Postgres.EventOutbox,
        clock: Robine.Adapters.System.Clock,
        id_generator: Robine.Adapters.System.IdGenerator
      },
      workflows: %WorkflowDependencies{
        decoder: Robine.Adapters.Workflow.YamlDecoder
      },
      execution: %ExecutionDependencies{
        runner: Robine.Adapters.Execution.DockerRunner
      },
      identities: identity_dependencies(),
      autoscaling: autoscaling_dependencies(),
      runners: runner_dependencies(),
      transfers: %TransferDependencies{archive: Robine.Adapters.Archive.SafeTar},
      operations: %OperationsDependencies{
        health: Robine.Adapters.System.SystemHealth,
        retention: Robine.Adapters.Persistence.Postgres.StorageRetention,
        blob_store: blob_store
      },
      secrets: %SecretDependencies{
        repository: Robine.Adapters.Persistence.Postgres.SecretRepository,
        cipher: Robine.Adapters.Security.AesGcmCipher,
        clock: Robine.Adapters.System.Clock,
        id_generator: Robine.Adapters.System.IdGenerator
      },
      storage: %StorageDependencies{
        repository: Robine.Adapters.Persistence.Postgres.StorageRepository,
        blob_store: blob_store,
        clock: Robine.Adapters.System.Clock,
        id_generator: Robine.Adapters.System.IdGenerator,
        instance_quota_bytes: Keyword.fetch!(storage_quotas, :instance_bytes),
        repository_quota_bytes: Keyword.fetch!(storage_quotas, :repository_bytes),
        gc_grace_seconds: Keyword.fetch!(retention, :gc_grace_seconds)
      },
      repositories: %RepositoryDependencies{
        repository: Robine.Adapters.Persistence.Postgres.GitHubRepository,
        webhook_verifier: Robine.Adapters.SourceControl.ProviderWebhookVerifier,
        source_control: Robine.Adapters.SourceControl.ProviderRegistry,
        clock: Robine.Adapters.System.Clock,
        id_generator: Robine.Adapters.System.IdGenerator,
        public_url: Application.fetch_env!(:robine, :public_url)
      }
    })
  end

  @spec validate!() :: :ok
  def validate! do
    storage_quotas = Application.fetch_env!(:robine, :storage_quotas)
    retention = Application.fetch_env!(:robine, :retention)
    blob_store = Application.fetch_env!(:robine, :blob_store_adapter)

    context(%{id: "startup", role: :administrator}, "startup")
    |> Map.fetch!(:dependencies)
    |> Map.fetch!(:pipelines)
    |> PipelineDependencies.validate!()

    WorkflowDependencies.validate!(%WorkflowDependencies{
      decoder: Robine.Adapters.Workflow.YamlDecoder
    })

    ExecutionDependencies.validate!(%ExecutionDependencies{
      runner: Robine.Adapters.Execution.DockerRunner
    })

    IdentityDependencies.validate!(identity_dependencies())
    AutoscalingDependencies.validate!(autoscaling_dependencies())
    RunnerDependencies.validate!(runner_dependencies())

    TransferDependencies.validate!(%TransferDependencies{
      archive: Robine.Adapters.Archive.SafeTar
    })

    OperationsDependencies.validate!(%OperationsDependencies{
      health: Robine.Adapters.System.SystemHealth,
      retention: Robine.Adapters.Persistence.Postgres.StorageRetention,
      blob_store: blob_store
    })

    SecretDependencies.validate!(%SecretDependencies{
      repository: Robine.Adapters.Persistence.Postgres.SecretRepository,
      cipher: Robine.Adapters.Security.AesGcmCipher,
      clock: Robine.Adapters.System.Clock,
      id_generator: Robine.Adapters.System.IdGenerator
    })

    Robine.Adapters.Security.AesGcmCipher.validate_configuration!()

    if blob_store == Robine.Adapters.Storage.S3BlobStore,
      do: Robine.Adapters.Storage.S3BlobStore.validate_configuration!()

    StorageDependencies.validate!(%StorageDependencies{
      repository: Robine.Adapters.Persistence.Postgres.StorageRepository,
      blob_store: blob_store,
      clock: Robine.Adapters.System.Clock,
      id_generator: Robine.Adapters.System.IdGenerator,
      instance_quota_bytes: Keyword.fetch!(storage_quotas, :instance_bytes),
      repository_quota_bytes: Keyword.fetch!(storage_quotas, :repository_bytes),
      gc_grace_seconds: Keyword.fetch!(retention, :gc_grace_seconds)
    })

    RepositoryDependencies.validate!(%RepositoryDependencies{
      repository: Robine.Adapters.Persistence.Postgres.GitHubRepository,
      webhook_verifier: Robine.Adapters.SourceControl.ProviderWebhookVerifier,
      source_control: Robine.Adapters.SourceControl.ProviderRegistry,
      clock: Robine.Adapters.System.Clock,
      id_generator: Robine.Adapters.System.IdGenerator,
      public_url: Application.fetch_env!(:robine, :public_url)
    })
  end

  defp identity_dependencies do
    %IdentityDependencies{
      repository: Robine.Adapters.Persistence.Postgres.IdentityRepository,
      passwords: Robine.Adapters.Security.Argon2Passwords,
      oidc: Application.fetch_env!(:robine, :oidc_adapter),
      oidc_config: Application.fetch_env!(:robine, :oidc_config),
      clock: Robine.Adapters.System.Clock,
      id_generator: Robine.Adapters.System.IdGenerator,
      bootstrap_token_hash: Application.fetch_env!(:robine, :bootstrap_token_hash),
      bootstrap_expires_at: Application.fetch_env!(:robine, :bootstrap_expires_at)
    }
  end

  defp runner_dependencies do
    %RunnerDependencies{
      registry: Robine.Adapters.Persistence.Postgres.RunnerRegistry,
      digester: Robine.Adapters.Security.HmacRunnerCredentials,
      token_generator: Robine.Adapters.Security.OpaqueTokenGenerator,
      session_notifier: Robine.Adapters.Runner.PhoenixSessionNotifier,
      clock: Robine.Adapters.System.Clock,
      id_generator: Robine.Adapters.System.IdGenerator
    }
  end

  defp autoscaling_dependencies do
    %AutoscalingDependencies{
      repository: Robine.Adapters.Persistence.Postgres.AutoscalingRepository,
      provider: Robine.Adapters.Autoscaling.DisabledProvider,
      clock: Robine.Adapters.System.Clock,
      id_generator: Robine.Adapters.System.IdGenerator
    }
  end
end
