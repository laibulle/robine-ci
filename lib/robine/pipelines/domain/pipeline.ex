defmodule Robine.Pipelines.Domain.Pipeline do
  @moduledoc "A durable CI pipeline and its creation invariants."

  @statuses [:created, :queued, :running, :cancelling, :succeeded, :failed, :cancelled, :invalid]

  @enforce_keys [
    :id,
    :repository_id,
    :workflow_name,
    :commit_sha,
    :trigger,
    :actor,
    :correlation_id,
    :status,
    :inserted_at
  ]
  defstruct [
    :id,
    :repository_id,
    :workflow_name,
    :commit_sha,
    :trigger,
    :actor,
    :correlation_id,
    :status,
    :inserted_at,
    :started_at,
    :finished_at,
    :scheduled_for,
    inputs: %{}
  ]

  @type status ::
          :created
          | :queued
          | :running
          | :cancelling
          | :succeeded
          | :failed
          | :cancelled
          | :invalid

  @type t :: %__MODULE__{
          id: String.t(),
          repository_id: String.t(),
          workflow_name: String.t(),
          commit_sha: String.t(),
          trigger: String.t(),
          actor: String.t(),
          correlation_id: String.t(),
          status: status(),
          inserted_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          scheduled_for: DateTime.t() | nil,
          inputs: %{optional(String.t()) => String.t()}
        }

  @spec create(map(), String.t(), DateTime.t()) :: {:ok, t()} | {:error, term()}
  def create(input, id, now) when is_map(input) and is_binary(id) do
    with {:ok, repository_id} <- required_string(input, :repository_id),
         {:ok, workflow_name} <- required_string(input, :workflow_name),
         {:ok, commit_sha} <- valid_sha(input),
         {:ok, inputs} <- valid_inputs(Map.get(input, :inputs, %{})),
         {:ok, scheduled_for} <- scheduled_for(Map.get(input, :scheduled_for)) do
      {:ok,
       %__MODULE__{
         id: id,
         repository_id: repository_id,
         workflow_name: workflow_name,
         commit_sha: commit_sha,
         trigger: optional_label(input, :trigger, "manual"),
         actor: optional_label(input, :actor, "system"),
         correlation_id: optional_label(input, :correlation_id, "unknown"),
         status: :created,
         inserted_at: DateTime.truncate(now, :microsecond),
         started_at: nil,
         finished_at: nil,
         scheduled_for: scheduled_for,
         inputs: inputs
       }}
    end
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec idempotent_id(String.t()) :: {:ok, String.t()} | {:error, :invalid_idempotency_key}
  def idempotent_id(key) when is_binary(key) and byte_size(key) in 1..512 do
    <<bytes::binary-size(16), _rest::binary>> = :crypto.hash(:sha256, key)

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> = Base.encode16(bytes, case: :lower)

    {:ok, Enum.join([a, b, c, d, e], "-")}
  end

  def idempotent_id(_key), do: {:error, :invalid_idempotency_key}

  @spec transition(t(), status()) :: {:ok, t()} | {:error, term()}
  def transition(%__MODULE__{status: current} = pipeline, target, now \\ nil) do
    if allowed_transition?(current, target) do
      {:ok, apply_timing(%{pipeline | status: target}, target, now)}
    else
      {:error, {:invalid_transition, :pipeline, current, target}}
    end
  end

  @spec request_cancellation(t()) :: {:ok, t()} | {:error, term()}
  def request_cancellation(pipeline, now \\ nil)

  def request_cancellation(%__MODULE__{status: :created} = pipeline, now),
    do: transition(pipeline, :cancelled, now)

  def request_cancellation(%__MODULE__{status: :queued} = pipeline, now),
    do: transition(pipeline, :cancelled, now)

  def request_cancellation(%__MODULE__{status: :running} = pipeline, now),
    do: transition(pipeline, :cancelling, now)

  def request_cancellation(%__MODULE__{status: :cancelling} = pipeline, _now), do: {:ok, pipeline}

  def request_cancellation(%__MODULE__{status: status}, _now),
    do: {:error, {:pipeline_terminal, status}}

  @spec reopen_for_retry(t()) :: {:ok, t()} | {:error, term()}
  def reopen_for_retry(pipeline, now \\ nil)

  def reopen_for_retry(%__MODULE__{status: status} = pipeline, now)
      when status in [:failed, :cancelled],
      do:
        {:ok, apply_timing(%{pipeline | status: :running, finished_at: nil}, :running, now, true)}

  def reopen_for_retry(%__MODULE__{status: status}, _now),
    do: {:error, {:pipeline_not_retryable, status}}

  @spec complete_from_jobs(t(), [Robine.Pipelines.Domain.Job.t()]) ::
          {:ok, t()} | {:error, term()}
  def complete_from_jobs(pipeline, jobs, now \\ nil)

  def complete_from_jobs(%__MODULE__{status: status} = pipeline, jobs, now)
      when status in [:running, :cancelling] and is_list(jobs) do
    if jobs != [] and Enum.all?(jobs, &Robine.Pipelines.Domain.Job.terminal?/1) do
      target = aggregate_job_result(status, jobs)
      transition(pipeline, target, now)
    else
      {:ok, pipeline}
    end
  end

  def complete_from_jobs(%__MODULE__{} = pipeline, _jobs, _now), do: {:ok, pipeline}

  defp aggregate_job_result(:cancelling, _jobs), do: :cancelled

  defp aggregate_job_result(_status, jobs) do
    cond do
      Enum.any?(jobs, &(&1.status == :failed)) -> :failed
      Enum.any?(jobs, &(&1.status == :cancelled)) -> :cancelled
      true -> :succeeded
    end
  end

  defp allowed_transition?(:created, target), do: target in [:queued, :cancelled, :invalid]
  defp allowed_transition?(:queued, target), do: target in [:running, :cancelled, :failed]

  defp allowed_transition?(:running, target),
    do: target in [:cancelling, :succeeded, :failed, :cancelled]

  defp allowed_transition?(:cancelling, target), do: target in [:cancelled, :failed]
  defp allowed_transition?(_terminal, _target), do: false

  defp required_string(input, field) do
    case Map.get(input, field) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:invalid_input, field, :required}}
    end
  end

  defp valid_sha(input) do
    with {:ok, sha} <- required_string(input, :commit_sha),
         true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, sha) do
      {:ok, sha}
    else
      false -> {:error, {:invalid_input, :commit_sha, :invalid_sha}}
      error -> error
    end
  end

  defp optional_label(input, field, default) do
    case Map.get(input, field) do
      value when is_binary(value) and value != "" ->
        String.slice(value, 0, 255)

      value when is_atom(value) and not is_nil(value) ->
        value |> to_string() |> String.slice(0, 255)

      _ ->
        default
    end
  end

  defp valid_inputs(inputs) when is_map(inputs) and map_size(inputs) <= 16 do
    if Enum.all?(inputs, fn {key, value} ->
         is_binary(key) and is_binary(value) and byte_size(key) <= 31 and
           byte_size(value) <= 1_024
       end),
       do: {:ok, inputs},
       else: {:error, {:invalid_input, :inputs, :invalid}}
  end

  defp valid_inputs(_inputs), do: {:error, {:invalid_input, :inputs, :invalid}}

  defp scheduled_for(nil), do: {:ok, nil}

  defp scheduled_for(%DateTime{} = scheduled_for),
    do: {:ok, DateTime.truncate(scheduled_for, :microsecond)}

  defp scheduled_for(_value), do: {:error, {:invalid_input, :scheduled_for, :invalid}}

  defp apply_timing(pipeline, target, now, force \\ false)

  defp apply_timing(pipeline, :running, %DateTime{} = now, force) do
    if force or is_nil(pipeline.started_at),
      do: %{pipeline | started_at: DateTime.truncate(now, :microsecond)},
      else: pipeline
  end

  defp apply_timing(pipeline, target, %DateTime{} = now, _force)
       when target in [:succeeded, :failed, :cancelled, :invalid],
       do: %{pipeline | finished_at: DateTime.truncate(now, :microsecond)}

  defp apply_timing(pipeline, _target, _now, _force), do: pipeline
end
