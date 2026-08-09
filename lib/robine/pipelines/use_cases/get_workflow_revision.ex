defmodule Robine.Pipelines.UseCases.GetWorkflowRevision do
  @moduledoc "Returns the immutable workflow revision used by one authorized pipeline."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Contracts.WorkflowRevisionView
  alias Robine.Pipelines.Dependencies

  @spec call(map(), ExecutionContext.t()) :: {:ok, WorkflowRevisionView.t()} | {:error, term()}
  def call(%{pipeline_id: pipeline_id}, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{pipelines: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer, :viewer] and is_binary(pipeline_id) do
    with {:ok, _pipeline} <- deps.pipeline_repository.get(pipeline_id),
         {:ok, revision} <- deps.pipeline_repository.get_revision(pipeline_id) do
      {:ok, struct!(WorkflowRevisionView, Map.from_struct(revision))}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
