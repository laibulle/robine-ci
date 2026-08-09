defmodule Robine.Execution.Domain.JobCondition do
  @moduledoc "Pure fixed-enum job condition policy used by local execution."

  @terminal [:succeeded, :failed, :cancelled, :skipped]

  @spec evaluate(:success | :failure | :always, [atom()]) :: :run | :skip | :wait
  def evaluate(condition, statuses) when condition in [:success, :failure, :always] do
    cond do
      not Enum.all?(statuses, &(&1 in @terminal)) -> :wait
      Enum.any?(statuses, &(&1 == :cancelled)) -> :skip
      condition == :success and Enum.all?(statuses, &(&1 == :succeeded)) -> :run
      condition == :failure and Enum.any?(statuses, &(&1 == :failed)) -> :run
      condition == :always -> :run
      true -> :skip
    end
  end
end
