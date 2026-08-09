defmodule Robine.Workflows.Dependencies do
  @moduledoc false

  @enforce_keys [:decoder]
  defstruct [:decoder]

  @type t :: %__MODULE__{decoder: module()}

  @spec validate!(t()) :: :ok
  def validate!(%__MODULE__{decoder: implementation}) do
    Code.ensure_loaded!(implementation)

    unless Robine.Workflows.Ports.Decoder in (implementation.module_info(:attributes)[:behaviour] ||
                                                []) do
      raise ArgumentError,
            "#{inspect(implementation)} must implement Robine.Workflows.Ports.Decoder"
    end

    :ok
  end
end
