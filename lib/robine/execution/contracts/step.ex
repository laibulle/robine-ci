defmodule Robine.Execution.Contracts.Step do
  @moduledoc "One normalized execution step."

  @enforce_keys [:name, :kind, :value]
  defstruct [:name, :kind, :value, with: %{}]

  @type kind :: :run | :builtin
  @type t :: %__MODULE__{name: String.t(), kind: kind(), value: String.t(), with: map()}
end
