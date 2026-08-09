defmodule Robine.Pipelines.UseCases.QueuePipeline do
  @moduledoc "Queues a newly created pipeline atomically."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Contracts.PipelineView
  alias Robine.Pipelines.Dependencies
  alias Robine.Pipelines.Domain.Pipeline

  @spec call(map(), ExecutionContext.t()) :: {:ok, PipelineView.t()} | {:error, term()}
  def call(%{pipeline_id: id}, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{pipelines: %Dependencies{} = deps}
      })
      when is_binary(id) and role in [:administrator, :maintainer] do
    deps.unit_of_work.transaction(fn ->
      with {:ok, pipeline} <- deps.pipeline_repository.get(id),
           {:ok, queued} <- queue(pipeline, deps.clock.now()),
           :ok <- deps.pipeline_repository.update(queued) do
        {:ok, PipelineView.from_domain(queued)}
      end
    end)
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp queue(%Pipeline{status: :queued} = pipeline, _now), do: {:ok, pipeline}
  defp queue(%Pipeline{status: :running} = pipeline, _now), do: {:ok, pipeline}
  defp queue(pipeline, now), do: Pipeline.transition(pipeline, :queued, now)
end
