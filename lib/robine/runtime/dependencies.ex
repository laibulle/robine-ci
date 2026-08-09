defmodule Robine.Runtime.Dependencies do
  @moduledoc "The sole production composition root for application dependencies."

  alias Robine.ExecutionContext
  alias Robine.Execution.Dependencies, as: ExecutionDependencies
  alias Robine.Identities.Dependencies, as: IdentityDependencies
  alias Robine.Operations.Dependencies, as: OperationsDependencies
  alias Robine.Pipelines.Dependencies, as: PipelineDependencies
  alias Robine.Repositories.Dependencies, as: RepositoryDependencies
  alias Robine.Secrets.Dependencies, as: SecretDependencies
  alias Robine.Storage.Dependencies, as: StorageDependencies
  alias Robine.Workflows.Dependencies, as: WorkflowDependencies

  @spec context(ExecutionContext.actor(), String.t()) :: ExecutionContext.t()
  def context(actor, correlation_id) do
    storage_quotas = Application.fetch_env!(:robine, :storage_quotas)

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
      operations: %OperationsDependencies{
        health: Robine.Adapters.System.SystemHealth,
        retention: Robine.Adapters.Persistence.Postgres.StorageRetention
      },
      secrets: %SecretDependencies{
        repository: Robine.Adapters.Persistence.Postgres.SecretRepository,
        cipher: Robine.Adapters.Security.AesGcmCipher,
        clock: Robine.Adapters.System.Clock,
        id_generator: Robine.Adapters.System.IdGenerator
      },
      storage: %StorageDependencies{
        repository: Robine.Adapters.Persistence.Postgres.StorageRepository,
        blob_store: Robine.Adapters.Storage.LocalBlobStore,
        clock: Robine.Adapters.System.Clock,
        id_generator: Robine.Adapters.System.IdGenerator,
        instance_quota_bytes: Keyword.fetch!(storage_quotas, :instance_bytes),
        repository_quota_bytes: Keyword.fetch!(storage_quotas, :repository_bytes)
      },
      repositories: %RepositoryDependencies{
        repository: Robine.Adapters.Persistence.Postgres.GitHubRepository,
        signature_verifier: Robine.Adapters.SourceControl.GitHubSignatureVerifier,
        github: Robine.Adapters.SourceControl.GitHubClient,
        clock: Robine.Adapters.System.Clock,
        id_generator: Robine.Adapters.System.IdGenerator,
        public_url: Application.fetch_env!(:robine, :public_url)
      }
    })
  end

  @spec validate!() :: :ok
  def validate! do
    storage_quotas = Application.fetch_env!(:robine, :storage_quotas)

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

    OperationsDependencies.validate!(%OperationsDependencies{
      health: Robine.Adapters.System.SystemHealth,
      retention: Robine.Adapters.Persistence.Postgres.StorageRetention
    })

    SecretDependencies.validate!(%SecretDependencies{
      repository: Robine.Adapters.Persistence.Postgres.SecretRepository,
      cipher: Robine.Adapters.Security.AesGcmCipher,
      clock: Robine.Adapters.System.Clock,
      id_generator: Robine.Adapters.System.IdGenerator
    })

    Robine.Adapters.Security.AesGcmCipher.validate_configuration!()

    StorageDependencies.validate!(%StorageDependencies{
      repository: Robine.Adapters.Persistence.Postgres.StorageRepository,
      blob_store: Robine.Adapters.Storage.LocalBlobStore,
      clock: Robine.Adapters.System.Clock,
      id_generator: Robine.Adapters.System.IdGenerator,
      instance_quota_bytes: Keyword.fetch!(storage_quotas, :instance_bytes),
      repository_quota_bytes: Keyword.fetch!(storage_quotas, :repository_bytes)
    })

    RepositoryDependencies.validate!(%RepositoryDependencies{
      repository: Robine.Adapters.Persistence.Postgres.GitHubRepository,
      signature_verifier: Robine.Adapters.SourceControl.GitHubSignatureVerifier,
      github: Robine.Adapters.SourceControl.GitHubClient,
      clock: Robine.Adapters.System.Clock,
      id_generator: Robine.Adapters.System.IdGenerator,
      public_url: Application.fetch_env!(:robine, :public_url)
    })
  end

  defp identity_dependencies do
    %IdentityDependencies{
      repository: Robine.Adapters.Persistence.Postgres.IdentityRepository,
      passwords: Robine.Adapters.Security.Argon2Passwords,
      oidc: Robine.Adapters.Identity.AssentOIDC,
      oidc_config: Application.fetch_env!(:robine, :oidc_config),
      clock: Robine.Adapters.System.Clock,
      id_generator: Robine.Adapters.System.IdGenerator,
      bootstrap_token_hash: Application.fetch_env!(:robine, :bootstrap_token_hash),
      bootstrap_expires_at: Application.fetch_env!(:robine, :bootstrap_expires_at)
    }
  end
end
