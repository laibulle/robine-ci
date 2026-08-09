defmodule Robine.Autoscaling do
  @moduledoc "Public API for provider-neutral runner capacity reconciliation."
  alias Robine.Autoscaling.UseCases
  alias Robine.ExecutionContext

  @spec create_policy(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate create_policy(input, context), to: UseCases.CreatePolicy, as: :call

  @spec fleet_capacity(map(), ExecutionContext.t()) :: {:ok, [map()]} | {:error, term()}
  defdelegate fleet_capacity(input, context), to: UseCases.GetFleetCapacity, as: :call

  @spec reconcile(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate reconcile(input, context), to: UseCases.ReconcileCapacity, as: :call
end
