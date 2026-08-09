defmodule Robine.Pipelines.Domain.Job do
  @moduledoc "A durable pipeline job and its dependency-aware lifecycle."

  @statuses [:blocked, :queued, :running, :cancelling, :succeeded, :failed, :cancelled, :skipped]
  @terminal [:succeeded, :failed, :cancelled, :skipped]

  @enforce_keys [:id, :pipeline_id, :job_key, :status, :needs, :position]
  defstruct [:id, :pipeline_id, :job_key, :status, :needs, :position, execution: %{}]

  @type status ::
          :blocked
          | :queued
          | :running
          | :cancelling
          | :succeeded
          | :failed
          | :cancelled
          | :skipped
  @type t :: %__MODULE__{
          id: String.t(),
          pipeline_id: String.t(),
          job_key: String.t(),
          status: status(),
          needs: [String.t()],
          position: non_neg_integer(),
          execution: map()
        }

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(
        %{id: id, pipeline_id: pipeline_id, job_key: key, needs: needs, position: position} =
          input
      )
      when is_binary(id) and is_binary(pipeline_id) and is_binary(key) and is_list(needs) and
             is_integer(position) and position >= 0 do
    execution = Map.get(input, :execution, %{})
    condition = Map.get(execution, "condition", "success")

    cond do
      condition not in ["success", "failure", "always"] ->
        {:error, {:invalid_job_condition, condition}}

      condition == "failure" and needs == [] ->
        {:error, {:invalid_job_condition, condition}}

      true ->
        status = if needs == [], do: :queued, else: :blocked

        {:ok,
         %__MODULE__{
           id: id,
           pipeline_id: pipeline_id,
           job_key: key,
           status: status,
           needs: needs,
           position: position,
           execution: execution
         }}
    end
  end

  def new(_input), do: {:error, {:invalid_input, :job}}

  @spec release(t(), %{optional(String.t()) => status()}) :: {:ok, t()} | {:error, term()}
  def release(%__MODULE__{status: :blocked} = job, dependency_statuses) do
    statuses = Enum.map(job.needs, &Map.get(dependency_statuses, &1))
    condition = Map.get(job.execution, "condition", "success")
    terminal? = Enum.all?(statuses, &(&1 in @terminal))

    cond do
      not terminal? ->
        {:ok, job}

      Enum.any?(statuses, &(&1 == :cancelled)) ->
        {:ok, %{job | status: :skipped}}

      condition == "success" and Enum.all?(statuses, &(&1 == :succeeded)) ->
        {:ok, %{job | status: :queued}}

      condition == "failure" and Enum.any?(statuses, &(&1 == :failed)) ->
        {:ok, %{job | status: :queued}}

      condition == "always" ->
        {:ok, %{job | status: :queued}}

      condition in ["success", "failure"] ->
        {:ok, %{job | status: :skipped}}

      true ->
        {:error, {:invalid_job_condition, condition}}
    end
  end

  def release(%__MODULE__{} = job, _dependency_statuses), do: {:ok, job}

  @spec transition(t(), status()) :: {:ok, t()} | {:error, term()}
  def transition(%__MODULE__{status: current} = job, target) do
    if allowed?(current, target),
      do: {:ok, %{job | status: target}},
      else: {:error, {:invalid_transition, :job, current, target}}
  end

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in @terminal

  @spec retry(t()) :: {:ok, t()} | {:error, term()}
  def retry(%__MODULE__{status: status} = job) when status in [:failed, :cancelled],
    do: {:ok, %{job | status: :queued}}

  def retry(%__MODULE__{status: status}), do: {:error, {:job_not_retryable, status}}

  @spec reset_for_rerun(t(), :queued | :blocked) :: {:ok, t()} | {:error, term()}
  def reset_for_rerun(%__MODULE__{status: status} = job, target)
      when status in @terminal and target in [:queued, :blocked],
      do: {:ok, %{job | status: target}}

  def reset_for_rerun(%__MODULE__{status: status}, _target),
    do: {:error, {:job_not_rerunnable, status}}

  defp allowed?(:blocked, target), do: target in [:queued, :cancelled, :skipped]
  defp allowed?(:queued, target), do: target in [:running, :cancelled]
  defp allowed?(:running, target), do: target in [:cancelling, :succeeded, :failed, :cancelled]
  defp allowed?(:cancelling, target), do: target in [:cancelled, :failed]
  defp allowed?(_terminal, _target), do: false
end
