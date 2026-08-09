defmodule Robine.Operations.Dependencies do
  @moduledoc false
  alias Robine.Operations.Ports.{Health, Retention}
  @enforce_keys [:health, :retention]
  defstruct [:health, :retention]
  @type t :: %__MODULE__{health: module(), retention: module()}

  def validate!(%__MODULE__{} = dependencies) do
    for {implementation, behaviour} <- [
          {dependencies.health, Health},
          {dependencies.retention, Retention}
        ] do
      Code.ensure_loaded!(implementation)

      unless behaviour in (implementation.module_info(:attributes)[:behaviour] || []),
        do:
          raise(ArgumentError, "#{inspect(implementation)} must implement #{inspect(behaviour)}")
    end

    :ok
  end
end
