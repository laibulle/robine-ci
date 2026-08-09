defmodule Robine.Pipelines.UseCases.ListActiveAttemptIds do
  @moduledoc "Returns opaque active attempt IDs for runner reconciliation."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies

  def call(_input, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{pipelines: %Dependencies{job_repository: repository}}
      }) do
    if function_exported?(repository, :list_active_attempt_ids, 0),
      do: repository.list_active_attempt_ids(),
      else: {:error, :active_attempt_projection_unavailable}
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
