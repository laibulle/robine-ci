defmodule Robine.Execution.UseCases.EvaluateJobCondition do
  @moduledoc "Evaluates one fixed local job condition without external dependencies."

  alias Robine.Execution.Domain.JobCondition

  @spec call(map()) :: {:ok, :run | :skip | :wait} | {:error, term()}
  def call(%{condition: condition, dependency_statuses: statuses})
      when condition in [:success, :failure, :always] and is_list(statuses) do
    {:ok, JobCondition.evaluate(condition, statuses)}
  end

  def call(_input), do: {:error, :invalid_job_condition_evaluation}
end
