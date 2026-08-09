defmodule Robine.Workflows.UseCases.EvaluateSchedule do
  @moduledoc "Purely evaluates one normalized schedule against a UTC minute."

  alias Robine.Workflows.Domain.{CronExpression, Schedule}

  @spec call(map()) :: {:ok, boolean()} | {:error, :invalid_schedule_evaluation}
  def call(%{schedule: %Schedule{expression: expression}, datetime: %DateTime{} = datetime}) do
    {:ok, CronExpression.matches?(expression, datetime)}
  end

  def call(_input), do: {:error, :invalid_schedule_evaluation}
end
