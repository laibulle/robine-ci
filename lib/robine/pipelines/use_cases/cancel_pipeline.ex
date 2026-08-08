defmodule Robine.Pipelines.UseCases.CancelPipeline do
  @moduledoc "Requests cancellation without losing terminal pipeline history."

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
           {:ok, cancelled} <- Pipeline.request_cancellation(pipeline),
           :ok <- deps.pipeline_repository.update(cancelled) do
        {:ok, PipelineView.from_domain(cancelled)}
      end
    end)
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
