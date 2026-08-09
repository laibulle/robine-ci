defmodule Robine.Execution.UseCases.ReconcileResources do
  @moduledoc "Removes runner-owned resources that have no active durable attempt."

  alias Robine.Execution.Dependencies
  alias Robine.ExecutionContext

  def call(%{active_attempt_ids: ids}, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{execution: %Dependencies{} = deps}
      })
      when is_list(ids) and length(ids) <= 10_000 do
    if Enum.all?(ids, &is_binary/1),
      do: deps.runner.reconcile_resources(ids),
      else: {:error, :invalid_active_attempt_ids}
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
