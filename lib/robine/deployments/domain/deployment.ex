defmodule Robine.Deployments.Domain.Deployment do
  @moduledoc "Immutable deployment intent and restart-safe transition policy."

  alias Robine.Deployments.Domain.{ArtifactSnapshot, Environment}

  @terminal [:succeeded, :failed, :cancelled, :verification_failed]
  @transitions %{
    requested: [:awaiting_approval, :queued, :cancelled],
    awaiting_approval: [:queued, :cancelled],
    queued: [:preparing, :cancelled, :failed],
    preparing: [:converging_services, :migrating, :cancelled, :failed],
    converging_services: [:migrating, :cancelled, :failed],
    migrating: [:activating, :failed],
    activating: [:verifying, :failed],
    verifying: [:succeeded, :verification_failed, :failed],
    verification_failed: [:verifying]
  }

  @enforce_keys [
    :id,
    :environment_id,
    :repository_id,
    :requester_id,
    :kind,
    :status,
    :artifact,
    :desired_state_digest,
    :environment_snapshot,
    :migration_policy,
    :event_sequence,
    :requested_at,
    :updated_at
  ]
  defstruct @enforce_keys ++
              [
                :approver_id,
                :approved_at,
                :attempt_id,
                :idempotency_token,
                :runner_id,
                :assigned_at,
                :lease_expires_at,
                :started_at,
                :finished_at,
                :failure_reason
              ]

  @type t :: %__MODULE__{}

  @spec new(map(), Environment.t(), ArtifactSnapshot.t(), DateTime.t()) ::
          {:ok, t()} | {:error, term()}
  def new(
        attributes,
        %Environment{} = environment,
        %ArtifactSnapshot{} = artifact,
        %DateTime{} = now
      ) do
    kind = Map.get(attributes, :kind, :application)
    requester_id = Map.get(attributes, :requester_id)
    id = Map.get(attributes, :id)

    cond do
      not present?(id) ->
        {:error, {:invalid_deployment, :id}}

      not present?(requester_id) ->
        {:error, {:invalid_deployment, :requester_id}}

      kind not in [:application, :platform, :rollback] ->
        {:error, {:invalid_deployment, :kind}}

      kind == :rollback and environment.migration_policy == :forward_only ->
        {:error, :rollback_forbidden}

      true ->
        status =
          if environment.protection == :protected or kind == :platform,
            do: :awaiting_approval,
            else: :queued

        {:ok,
         %__MODULE__{
           id: id,
           environment_id: environment.id,
           repository_id: environment.repository_id,
           requester_id: requester_id,
           kind: kind,
           status: status,
           artifact: artifact,
           desired_state_digest: environment.desired_state_digest,
           environment_snapshot: Map.from_struct(environment),
           migration_policy: environment.migration_policy,
           event_sequence: 0,
           requested_at: now,
           updated_at: now
         }}
    end
  end

  @spec approve(t(), String.t(), DateTime.t()) :: {:ok, t()} | {:error, term()}
  def approve(
        %__MODULE__{status: :awaiting_approval, requester_id: requester} = deployment,
        actor,
        now
      )
      when is_binary(actor) and actor != requester do
    {:ok,
     %{
       deployment
       | status: :queued,
         approver_id: actor,
         approved_at: now,
         updated_at: now
     }}
  end

  def approve(%__MODULE__{requester_id: actor}, actor, _now), do: {:error, :self_approval}
  def approve(%__MODULE__{}, _actor, _now), do: {:error, :invalid_deployment_transition}

  @spec assign(t(), String.t(), String.t(), String.t(), DateTime.t(), DateTime.t()) ::
          {:ok, t()} | {:error, term()}
  def assign(
        %__MODULE__{status: :queued, runner_id: nil} = deployment,
        runner_id,
        attempt_id,
        idempotency_token,
        %DateTime{} = assigned_at,
        %DateTime{} = lease_expires_at
      )
      when is_binary(runner_id) and is_binary(attempt_id) and is_binary(idempotency_token) do
    if runner_id != "" and attempt_id != "" and idempotency_token != "" and
         DateTime.compare(lease_expires_at, assigned_at) == :gt do
      {:ok,
       %{
         deployment
         | runner_id: runner_id,
           attempt_id: attempt_id,
           idempotency_token: idempotency_token,
           assigned_at: assigned_at,
           lease_expires_at: lease_expires_at,
           updated_at: assigned_at
       }}
    else
      {:error, :invalid_deployment_assignment}
    end
  end

  def assign(%__MODULE__{}, _runner, _attempt, _token, _assigned, _lease),
    do: {:error, :deployment_not_assignable}

  @spec record_event(t(), non_neg_integer(), atom(), String.t() | nil, DateTime.t()) ::
          {:ok, t()} | {:error, term()}
  def record_event(%__MODULE__{} = deployment, sequence, status, reason, %DateTime{} = now)
      when is_integer(sequence) and sequence > 0 and is_atom(status) do
    cond do
      sequence != deployment.event_sequence + 1 ->
        {:error, :invalid_event_sequence}

      status not in Map.get(@transitions, deployment.status, []) ->
        {:error, :invalid_deployment_transition}

      not valid_reason?(reason) ->
        {:error, :invalid_failure_reason}

      true ->
        {:ok,
         %{
           deployment
           | status: status,
             event_sequence: sequence,
             started_at: deployment.started_at || started_at(status, now),
             finished_at: finished_at(status, now),
             failure_reason: if(status in [:failed, :verification_failed], do: reason, else: nil),
             updated_at: now
         }}
    end
  end

  def record_event(%__MODULE__{}, _sequence, _status, _reason, _now),
    do: {:error, :invalid_runner_event}

  @spec cancel(t(), DateTime.t()) :: {:ok, t()} | {:error, term()}
  def cancel(%__MODULE__{status: status} = deployment, %DateTime{} = now)
      when status in [:requested, :awaiting_approval, :queued, :preparing, :converging_services] do
    {:ok,
     %{
       deployment
       | status: :cancelled,
         finished_at: now,
         updated_at: now,
         failure_reason: "cancelled"
     }}
  end

  def cancel(%__MODULE__{}, _now), do: {:error, :deployment_not_cancellable}

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in @terminal

  defp present?(value), do: is_binary(value) and value != ""
  defp valid_reason?(nil), do: true
  defp valid_reason?(reason), do: is_binary(reason) and byte_size(reason) in 1..256
  defp started_at(:preparing, now), do: now
  defp started_at(_status, _now), do: nil
  defp finished_at(status, now) when status in @terminal, do: now
  defp finished_at(_status, _now), do: nil
end
