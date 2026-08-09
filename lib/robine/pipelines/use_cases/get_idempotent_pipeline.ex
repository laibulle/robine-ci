defmodule Robine.Pipelines.UseCases.GetIdempotentPipeline do
  @moduledoc "Returns the pipeline already assigned to a caller-owned idempotency key."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Contracts.PipelineView
  alias Robine.Pipelines.Dependencies
  alias Robine.Pipelines.Domain.Pipeline

  @spec call(map(), ExecutionContext.t()) :: {:ok, PipelineView.t()} | {:error, term()}
  def call(
        %{idempotency_key: key},
        %ExecutionContext{
          actor: %{role: role},
          dependencies: %{pipelines: %Dependencies{} = deps}
        }
      )
      when role in [:administrator, :maintainer] and is_binary(key) do
    with {:ok, id} <- Pipeline.idempotent_id(key),
         {:ok, pipeline} <- deps.pipeline_repository.get(id) do
      {:ok, PipelineView.from_domain(pipeline)}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
