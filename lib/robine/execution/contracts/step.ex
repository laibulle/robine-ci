defmodule Robine.Execution.Contracts.Step do
  @moduledoc "One normalized execution step."

  @enforce_keys [:name, :kind, :value]
  defstruct [:name, :kind, :value, condition: :success, with: %{}]

  @type kind :: :run | :builtin
  @type t :: %__MODULE__{
          name: String.t(),
          kind: kind(),
          value: String.t(),
          condition: :success | :failure | :always,
          with: map()
        }
end
