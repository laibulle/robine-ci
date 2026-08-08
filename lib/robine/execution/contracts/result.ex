defmodule Robine.Execution.Contracts.Result do
  @moduledoc "Result of one complete job execution."

  alias Robine.Execution.Contracts.StepResult

  @enforce_keys [:attempt_id, :status, :steps, :started_at, :finished_at]
  defstruct [
    :attempt_id,
    :status,
    :reason,
    :steps,
    :started_at,
    :finished_at,
    cleanup_warning: nil
  ]

  @type t :: %__MODULE__{
          attempt_id: String.t(),
          status: :succeeded | :failed,
          reason: :command_failed | :timeout | :system_failure | nil,
          steps: [StepResult.t()],
          started_at: DateTime.t(),
          finished_at: DateTime.t(),
          cleanup_warning: String.t() | nil
        }
end
