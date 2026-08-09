defmodule Robine.Autoscaling.UseCases.GetFleetCapacity do
  @moduledoc "Projects desired versus observed autoscaling capacity and provider health."
  alias Robine.Autoscaling.Dependencies
  alias Robine.Autoscaling.Domain.DesiredCapacity
  alias Robine.ExecutionContext

  def call(_input, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{autoscaling: %Dependencies{} = deps}
      }) do
    with {:ok, policies} <- deps.repository.list_policies() do
      {:ok, Enum.map(policies, &project(&1, deps))}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp project(policy, deps) do
    with {:ok, demand} <- deps.repository.queued_demand(policy.labels),
         {:ok, instances} <- deps.provider.describe(policy.runner_template) do
      observed = length(instances)
      busy = Enum.count(instances, &(Map.get(&1, :active_leases, 0) > 0))

      %{
        id: policy.id,
        policy_id: policy.id,
        name: policy.name,
        enabled: policy.enabled,
        provider: policy.provider,
        desired: DesiredCapacity.calculate(policy, observed, busy, demand),
        observed: observed,
        queued_demand: demand,
        health: provider_health(instances),
        error: nil
      }
    else
      {:error, reason} ->
        %{
          id: policy.id,
          policy_id: policy.id,
          name: policy.name,
          enabled: policy.enabled,
          provider: policy.provider,
          desired: nil,
          observed: nil,
          queued_demand: nil,
          health: :degraded,
          error: safe_error(reason)
        }
    end
  end

  defp provider_health(instances) do
    if Enum.any?(instances, &(Map.get(&1, :state) == :degraded)), do: :degraded, else: :healthy
  end

  defp safe_error(reason) when is_atom(reason), do: reason
  defp safe_error(_reason), do: :provider_error
end
