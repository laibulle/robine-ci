defmodule Robine.Execution.Dependencies do
  @moduledoc false

  @enforce_keys [:runner]
  defstruct [:runner]

  @type t :: %__MODULE__{runner: module()}

  @spec validate!(t()) :: :ok
  def validate!(%__MODULE__{runner: implementation}) do
    Code.ensure_loaded!(implementation)

    unless Robine.Execution.Ports.Runner in (implementation.module_info(:attributes)[:behaviour] ||
                                               []) do
      raise ArgumentError,
            "#{inspect(implementation)} must implement Robine.Execution.Ports.Runner"
    end

    :ok
  end
end
