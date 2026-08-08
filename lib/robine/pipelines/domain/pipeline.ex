defmodule Robine.Pipelines.Domain.Pipeline do
  @moduledoc "A durable CI pipeline and its creation invariants."

  @statuses [:created, :queued, :running, :cancelling, :succeeded, :failed, :cancelled, :invalid]

  @enforce_keys [:id, :repository_id, :workflow_name, :commit_sha, :status, :inserted_at]
  defstruct [:id, :repository_id, :workflow_name, :commit_sha, :status, :inserted_at]

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
          status: status(),
          inserted_at: DateTime.t()
        }

  @spec create(map(), String.t(), DateTime.t()) :: {:ok, t()} | {:error, term()}
  def create(input, id, now) when is_map(input) and is_binary(id) do
    with {:ok, repository_id} <- required_string(input, :repository_id),
         {:ok, workflow_name} <- required_string(input, :workflow_name),
         {:ok, commit_sha} <- valid_sha(input) do
      {:ok,
       %__MODULE__{
         id: id,
         repository_id: repository_id,
         workflow_name: workflow_name,
         commit_sha: commit_sha,
         status: :created,
         inserted_at: DateTime.truncate(now, :microsecond)
       }}
    end
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec transition(t(), status()) :: {:ok, t()} | {:error, term()}
  def transition(%__MODULE__{status: current} = pipeline, target) do
    if allowed_transition?(current, target) do
      {:ok, %{pipeline | status: target}}
    else
      {:error, {:invalid_transition, :pipeline, current, target}}
    end
  end

  @spec request_cancellation(t()) :: {:ok, t()} | {:error, term()}
  def request_cancellation(%__MODULE__{status: :created} = pipeline),
    do: transition(pipeline, :cancelled)

  def request_cancellation(%__MODULE__{status: :queued} = pipeline),
    do: transition(pipeline, :cancelled)

  def request_cancellation(%__MODULE__{status: :running} = pipeline),
    do: transition(pipeline, :cancelling)

  def request_cancellation(%__MODULE__{status: :cancelling} = pipeline), do: {:ok, pipeline}

  def request_cancellation(%__MODULE__{status: status}),
    do: {:error, {:pipeline_terminal, status}}

  @spec complete_from_jobs(t(), [Robine.Pipelines.Domain.Job.t()]) ::
          {:ok, t()} | {:error, term()}
  def complete_from_jobs(%__MODULE__{status: status} = pipeline, jobs)
      when status in [:running, :cancelling] and is_list(jobs) do
    if jobs != [] and Enum.all?(jobs, &Robine.Pipelines.Domain.Job.terminal?/1) do
      target = aggregate_job_result(status, jobs)
      transition(pipeline, target)
    else
      {:ok, pipeline}
    end
  end

  def complete_from_jobs(%__MODULE__{} = pipeline, _jobs), do: {:ok, pipeline}

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
end
