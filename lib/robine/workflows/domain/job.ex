defmodule Robine.Workflows.Domain.Job do
  @moduledoc "A normalized container job in a workflow graph."

  alias Robine.Workflows.Domain.Step

  @enforce_keys [:id, :image, :needs, :steps]
  defstruct [:id, :image, :needs, :steps, :timeout, env: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          image: String.t(),
          needs: [String.t()],
          steps: [Step.t()],
          timeout: String.t() | nil,
          env: %{optional(String.t()) => String.t()}
        }
end
