defmodule Robine.Adapters.Persistence.Postgres.AutoscalingRepository do
  @moduledoc false
  @behaviour Robine.Autoscaling.Ports.Repository
  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    AuditEvent,
    AutoscalingIntent,
    AutoscalingPolicy,
    Job
  }

  alias Robine.Autoscaling.Domain.Policy
  alias Robine.Repo

  @impl true
  def insert_policy(%Policy{} = policy, audit) do
    Repo.transaction(fn ->
      with {:ok, _stored} <-
             AutoscalingPolicy.changeset(%AutoscalingPolicy{}, Map.from_struct(policy))
             |> Repo.insert(),
           {:ok, _audit} <-
             AuditEvent.changeset(%AuditEvent{}, %{
               actor_id: audit.actor_id,
               action: "autoscaling.policy_created",
               target_type: "autoscaling_policy",
               target_id: policy.id,
               occurred_at: policy.inserted_at,
               metadata: %{correlation_id: audit.correlation_id, provider: policy.provider}
             })
             |> Repo.insert() do
        :ok
      else
        {:error, changeset} -> Repo.rollback({:autoscaling_persistence, changeset})
      end
    end)
    |> unwrap()
  end

  @impl true
  def list_policies do
    {:ok,
     Repo.all(from policy in AutoscalingPolicy, order_by: [asc: policy.name])
     |> Enum.map(&domain/1)}
  end

  @impl true
  def queued_demand(labels) do
    jobs = Repo.all(from job in Job, where: job.status == :queued, select: job.execution_spec)

    {:ok,
     Enum.count(jobs, fn execution ->
       requested = Map.get(execution, "runs_on", ["docker"])
       is_list(requested) and Enum.all?(requested, &(&1 in labels))
     end)}
  end

  @impl true
  def last_completed_effect(policy_id, action) do
    {:ok,
     Repo.one(
       from intent in AutoscalingIntent,
         where:
           intent.policy_id == ^policy_id and intent.action == ^action and
             intent.status == :completed,
         order_by: [desc: intent.completed_at],
         limit: 1,
         select: intent.completed_at
     )}
  end

  @impl true
  def reserve_intent(attributes) do
    changes =
      attributes
      |> Map.put(:status, :pending)
      |> Map.put(:attempted_at, attributes.now)
      |> Map.delete(:now)

    case AutoscalingIntent.changeset(%AutoscalingIntent{}, changes)
         |> Repo.insert(
           on_conflict: {:replace, [:attempted_at, :updated_at]},
           conflict_target: :idempotency_key,
           returning: true
         ) do
      {:ok, intent} -> {:ok, intent_view(intent)}
      {:error, changeset} -> {:error, {:autoscaling_persistence, changeset}}
    end
  end

  @impl true
  def complete_intent(id, now),
    do: update_intent(id, status: :completed, completed_at: now, last_error: nil)

  @impl true
  def fail_intent(id, error, now),
    do: update_intent(id, status: :failed, attempted_at: now, last_error: error)

  defp update_intent(id, changes) do
    case Repo.get(AutoscalingIntent, id) do
      nil ->
        {:error, :not_found}

      intent ->
        case intent |> Ecto.Changeset.change(changes) |> Repo.update() do
          {:ok, _intent} -> :ok
          {:error, changeset} -> {:error, {:autoscaling_persistence, changeset}}
        end
    end
  end

  defp intent_view(intent),
    do: %{id: intent.id, status: intent.status, idempotency_key: intent.idempotency_key}

  defp domain(schema) do
    {:ok, policy} = Policy.new(Map.from_struct(schema))
    policy
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, reason}), do: {:error, reason}
end
