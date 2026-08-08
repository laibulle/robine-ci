defmodule Robine.Pipelines.Domain.Attempt do
  @moduledoc "One immutable-history execution attempt for a job."

  @statuses [:queued, :preparing, :running, :cancelling, :succeeded, :failed, :cancelled]
  @reasons [:command_failed, :timeout, :runner_lost, :system_failure, :cancelled]

  @enforce_keys [:id, :job_id, :number, :idempotency_token, :status, :lease_expires_at]
  defstruct [
    :id,
    :job_id,
    :number,
    :idempotency_token,
    :status,
    :lease_expires_at,
    :last_sequence,
    :result_reason
  ]

  @type status ::
          :queued | :preparing | :running | :cancelling | :succeeded | :failed | :cancelled
  @type reason :: :command_failed | :timeout | :runner_lost | :system_failure | :cancelled
  @type t :: %__MODULE__{
          id: String.t(),
          job_id: String.t(),
          number: pos_integer(),
          idempotency_token: String.t(),
          status: status(),
          lease_expires_at: DateTime.t(),
          last_sequence: non_neg_integer() | nil,
          result_reason: reason() | nil
        }

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(%{
        id: id,
        job_id: job_id,
        number: number,
        idempotency_token: token,
        lease_expires_at: %DateTime{} = lease
      })
      when is_binary(id) and is_binary(job_id) and is_integer(number) and number > 0 and
             is_binary(token) do
    {:ok,
     %__MODULE__{
       id: id,
       job_id: job_id,
       number: number,
       idempotency_token: token,
       status: :queued,
       lease_expires_at: lease,
       last_sequence: 0
     }}
  end

  def new(_input), do: {:error, {:invalid_input, :attempt}}

  @spec record_event(t(), non_neg_integer(), status(), reason() | nil) ::
          {:ok, t()} | {:error, term()}
  def record_event(%__MODULE__{last_sequence: last} = attempt, sequence, target, reason \\ nil)
      when is_integer(sequence) and sequence >= 0 do
    cond do
      sequence <= last ->
        {:ok, attempt}

      sequence != last + 1 ->
        {:error, {:event_gap, last + 1, sequence}}

      not valid_reason?(target, reason) ->
        {:error, {:invalid_result_reason, target, reason}}

      not allowed?(attempt.status, target) ->
        {:error, {:invalid_transition, :attempt, attempt.status, target}}

      true ->
        {:ok, %{attempt | status: target, last_sequence: sequence, result_reason: reason}}
    end
  end

  @spec lease_expired?(t(), DateTime.t()) :: boolean()
  def lease_expired?(%__MODULE__{lease_expires_at: lease}, now),
    do: DateTime.compare(lease, now) == :lt

  defp valid_reason?(:failed, reason), do: reason in (@reasons -- [:cancelled])
  defp valid_reason?(:cancelled, :cancelled), do: true
  defp valid_reason?(_status, nil), do: true
  defp valid_reason?(_status, _reason), do: false

  defp allowed?(:queued, target), do: target in [:preparing, :cancelled, :failed]
  defp allowed?(:preparing, target), do: target in [:running, :cancelling, :cancelled, :failed]
  defp allowed?(:running, target), do: target in [:cancelling, :succeeded, :failed, :cancelled]
  defp allowed?(:cancelling, target), do: target in [:cancelled, :failed]
  defp allowed?(_terminal, _target), do: false
end
