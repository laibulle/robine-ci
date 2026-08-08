defmodule Robine.Runtime.Dependencies do
  @moduledoc "The sole production composition root for application dependencies."

  alias Robine.ExecutionContext
  alias Robine.Execution.Dependencies, as: ExecutionDependencies
  alias Robine.Pipelines.Dependencies, as: PipelineDependencies
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
  end
end
