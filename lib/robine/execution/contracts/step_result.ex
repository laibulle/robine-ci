defmodule Robine.Execution.Contracts.StepResult do
  @moduledoc "Terminal result and bounded output for one execution step."

  @enforce_keys [:name, :status, :exit_code, :output, :duration_ms]
  defstruct [:name, :status, :exit_code, :output, :duration_ms]

  @type t :: %__MODULE__{
          name: String.t(),
          status: :succeeded | :failed | :timed_out,
          exit_code: integer() | nil,
          output: String.t(),
          duration_ms: non_neg_integer()
        }
end
