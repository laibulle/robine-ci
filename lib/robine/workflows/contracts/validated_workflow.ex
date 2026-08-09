defmodule Robine.Workflows.Contracts.ValidatedWorkflow do
  @moduledoc "Stable validation result shared by the server and CLI."

  alias Robine.Workflows.Domain.{Diagnostic, Workflow}

  @enforce_keys [:path, :workflow, :warnings]
  defstruct [:path, :workflow, :warnings, sources: %{}]

  @type t :: %__MODULE__{
          path: String.t(),
          workflow: Workflow.t(),
          warnings: [Diagnostic.t()],
          sources: %{optional(String.t()) => binary()}
        }
end
