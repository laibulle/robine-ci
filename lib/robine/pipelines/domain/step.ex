defmodule Robine.Pipelines.Domain.Step do
  @moduledoc "Durable execution state for one job step."

  @statuses [:pending, :running, :succeeded, :failed, :cancelled, :skipped]

  @enforce_keys [:id, :attempt_id, :name, :position, :status]
  defstruct [:id, :attempt_id, :name, :position, :status, :exit_code]

  @type status :: :pending | :running | :succeeded | :failed | :cancelled | :skipped
  @type t :: %__MODULE__{
          id: String.t(),
          attempt_id: String.t(),
          name: String.t(),
          position: non_neg_integer(),
          status: status(),
          exit_code: integer() | nil
        }

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec transition(t(), status(), integer() | nil) :: {:ok, t()} | {:error, term()}
  def transition(%__MODULE__{status: current} = step, target, exit_code \\ nil) do
    if allowed?(current, target, exit_code),
      do: {:ok, %{step | status: target, exit_code: exit_code}},
      else: {:error, {:invalid_transition, :step, current, target}}
  end

  defp allowed?(:pending, :running, nil), do: true
  defp allowed?(:pending, target, nil), do: target in [:cancelled, :skipped]
  defp allowed?(:running, :succeeded, 0), do: true
  defp allowed?(:running, :failed, code), do: is_integer(code) and code != 0
  defp allowed?(:running, :cancelled, nil), do: true
  defp allowed?(_current, _target, _code), do: false
end
