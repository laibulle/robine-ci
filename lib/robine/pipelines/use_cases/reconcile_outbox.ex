defmodule Robine.Pipelines.UseCases.ReconcileOutbox do
  @moduledoc "Recreates durable delivery jobs for pending outbox events."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies

  @spec call(map(), ExecutionContext.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def call(input, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{pipelines: %Dependencies{} = deps}
      }) do
    limit = positive(Map.get(input, :limit, 100), 100)
    deps.event_outbox.reconcile_pending(limit)
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
