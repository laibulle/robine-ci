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
    status = if needs == [], do: :queued, else: :blocked

    {:ok,
     %__MODULE__{
       id: id,
       pipeline_id: pipeline_id,
       job_key: key,
       status: status,
       needs: needs,
       position: position,
       execution: Map.get(input, :execution, %{})
     }}
  end

  def new(_input), do: {:error, {:invalid_input, :job}}

  @spec release(t(), %{optional(String.t()) => status()}) :: {:ok, t()} | {:error, term()}
  def release(%__MODULE__{status: :blocked} = job, dependency_statuses) do
    statuses = Enum.map(job.needs, &Map.get(dependency_statuses, &1))

    cond do
      Enum.all?(statuses, &(&1 == :succeeded)) ->
        {:ok, %{job | status: :queued}}

      Enum.any?(statuses, &(&1 in [:failed, :cancelled, :skipped])) ->
        {:ok, %{job | status: :skipped}}

      true ->
        {:ok, job}
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

  defp allowed?(:blocked, target), do: target in [:queued, :cancelled, :skipped]
  defp allowed?(:queued, target), do: target in [:running, :cancelled]
  defp allowed?(:running, target), do: target in [:cancelling, :succeeded, :failed, :cancelled]
  defp allowed?(:cancelling, target), do: target in [:cancelled, :failed]
  defp allowed?(_terminal, _target), do: false
end
