defmodule Robine.Autoscaling.UseCases.ReconcileCapacity do
  @moduledoc "Reconciles durable capacity intents before applying provider effects."
  alias Robine.Autoscaling.Dependencies
  alias Robine.Autoscaling.Domain.DesiredCapacity
  alias Robine.ExecutionContext

  def call(_input, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{autoscaling: %Dependencies{} = deps}
      }) do
    with {:ok, policies} <- deps.repository.list_policies() do
      policies
      |> Enum.filter(& &1.enabled)
      |> Enum.reduce_while({:ok, %{policies: 0, effects: 0}}, fn policy, {:ok, totals} ->
        case reconcile_policy(policy, deps) do
          {:ok, effects} ->
            {:cont, {:ok, %{policies: totals.policies + 1, effects: totals.effects + effects}}}

          {:error, reason} ->
            {:halt, {:error, {:policy_reconciliation_failed, policy.id, reason}}}
        end
      end)
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp reconcile_policy(policy, deps) do
    with {:ok, demand} <- deps.repository.queued_demand(policy.labels),
         {:ok, instances} <- deps.provider.describe(policy.runner_template) do
      observed = length(instances)
      busy = Enum.count(instances, &(Map.get(&1, :active_leases, 0) > 0))
      desired = DesiredCapacity.calculate(policy, observed, busy, demand)

      cond do
        desired > observed -> maybe_provision(policy, desired, observed, deps)
        desired < observed -> maybe_terminate(policy, instances, desired, observed, deps)
        true -> {:ok, 0}
      end
    end
  end

  defp maybe_provision(policy, desired, observed, deps) do
    if cooldown_elapsed?(policy, :provision, deps) do
      intent(policy, :provision, nil, desired, observed, deps, fn key ->
        deps.provider.provision(policy.runner_template, key)
      end)
    else
      {:ok, 0}
    end
  end

  defp maybe_terminate(policy, instances, desired, observed, deps) do
    cutoff = DateTime.add(deps.clock.now(), -policy.idle_timeout_seconds, :second)

    candidate =
      instances
      |> Enum.filter(&(Map.get(&1, :active_leases, 0) == 0))
      |> Enum.filter(fn instance ->
        case Map.get(instance, :last_active_at) do
          %DateTime{} = last -> DateTime.compare(last, cutoff) != :gt
          _unknown -> false
        end
      end)
      |> Enum.sort_by(&Map.get(&1, :last_active_at), DateTime)
      |> List.first()

    if candidate && cooldown_elapsed?(policy, :terminate, deps) do
      intent(policy, :terminate, candidate.id, desired, observed, deps, fn key ->
        case deps.provider.terminate(candidate.id, key) do
          :ok -> {:ok, %{instance_id: candidate.id}}
          error -> error
        end
      end)
    else
      {:ok, 0}
    end
  end

  defp intent(policy, action, target, desired, observed, deps, effect) do
    key = intent_key(policy.id, action, target, desired, observed)

    with {:ok, intent} <-
           deps.repository.reserve_intent(%{
             id: deps.id_generator.generate(),
             policy_id: policy.id,
             idempotency_key: key,
             action: action,
             target_instance_id: target,
             desired_capacity: desired,
             observed_capacity: observed,
             now: deps.clock.now()
           }) do
      if intent.status == :completed do
        {:ok, 0}
      else
        apply_effect(intent.id, key, deps, effect)
      end
    end
  end

  defp apply_effect(intent_id, key, deps, effect) do
    case effect.(key) do
      {:ok, _result} ->
        with :ok <- deps.repository.complete_intent(intent_id, deps.clock.now()), do: {:ok, 1}

      {:error, reason} ->
        _ = deps.repository.fail_intent(intent_id, safe_error(reason), deps.clock.now())
        {:error, reason}
    end
  end

  defp cooldown_elapsed?(policy, action, deps) do
    seconds =
      if action == :provision,
        do: policy.scale_up_cooldown_seconds,
        else: policy.scale_down_cooldown_seconds

    case deps.repository.last_completed_effect(policy.id, action) do
      {:ok, nil} -> true
      {:ok, %DateTime{} = last} -> DateTime.diff(deps.clock.now(), last, :second) >= seconds
      {:error, _reason} -> false
    end
  end

  defp intent_key(policy_id, action, target, desired, observed) do
    :crypto.hash(:sha256, "#{policy_id}:#{action}:#{target}:#{desired}:#{observed}")
    |> Base.encode16(case: :lower)
  end

  defp safe_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error(_reason), do: "provider_error"
end
