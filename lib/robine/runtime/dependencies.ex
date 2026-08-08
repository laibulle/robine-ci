defmodule Robine.Runtime.Dependencies do
  @moduledoc "The sole production composition root for application dependencies."

  alias Robine.ExecutionContext
  alias Robine.Execution.Dependencies, as: ExecutionDependencies
  alias Robine.Pipelines.Dependencies, as: PipelineDependencies
  alias Robine.Repositories.Dependencies, as: RepositoryDependencies
  alias Robine.Secrets.Dependencies, as: SecretDependencies
  alias Robine.Storage.Dependencies, as: StorageDependencies
  alias Robine.Workflows.Dependencies, as: WorkflowDependencies

  @spec context(ExecutionContext.actor(), String.t()) :: ExecutionContext.t()
  def context(actor, correlation_id) do
    ExecutionContext.new(actor, correlation_id, %{
      pipelines: %PipelineDependencies{
        unit_of_work: Robine.Adapters.Persistence.Postgres.UnitOfWork,
        pipeline_repository: Robine.Adapters.Persistence.Postgres.PipelineRepository,
        job_repository: Robine.Adapters.Persistence.Postgres.JobRepository,
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
        id_generator: Robine.Adapters.System.IdGenerator
      },
      repositories: %RepositoryDependencies{
        repository: Robine.Adapters.Persistence.Postgres.GitHubRepository,
        signature_verifier: Robine.Adapters.SourceControl.GitHubSignatureVerifier,
        github: Robine.Adapters.SourceControl.GitHubClient,
        clock: Robine.Adapters.System.Clock,
        id_generator: Robine.Adapters.System.IdGenerator
      }
    })
  end

  @spec validate!() :: :ok
  def validate! do
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
      id_generator: Robine.Adapters.System.IdGenerator
    })

    RepositoryDependencies.validate!(%RepositoryDependencies{
      repository: Robine.Adapters.Persistence.Postgres.GitHubRepository,
      signature_verifier: Robine.Adapters.SourceControl.GitHubSignatureVerifier,
      github: Robine.Adapters.SourceControl.GitHubClient,
      clock: Robine.Adapters.System.Clock,
      id_generator: Robine.Adapters.System.IdGenerator
    })
  end
end
