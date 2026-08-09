defmodule Robine.Workflows.Domain.Schedule do
  @moduledoc "A validated UTC workflow schedule."

  alias Robine.Workflows.Domain.CronExpression

  @enforce_keys [:cron, :expression]
  defstruct [:cron, :expression]

  @type t :: %__MODULE__{cron: String.t(), expression: CronExpression.t()}
end
