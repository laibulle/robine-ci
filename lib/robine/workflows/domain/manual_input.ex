defmodule Robine.Workflows.Domain.ManualInput do
  @moduledoc "One normalized non-secret input declared by a manual workflow trigger."

  @enforce_keys [:id, :type, :required]
  defstruct [:id, :description, :default, :options, :type, required: false]

  @type input_type :: :string | :choice | :boolean
  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t() | nil,
          type: input_type(),
          required: boolean(),
          default: String.t() | nil,
          options: [String.t()] | nil
        }
end
