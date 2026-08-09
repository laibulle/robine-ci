defmodule Robine.Autoscaling.Dependencies do
  @moduledoc false
  alias Robine.Autoscaling.Ports

  @enforce_keys [:repository, :provider, :clock, :id_generator]
  defstruct @enforce_keys

  def validate!(%__MODULE__{} = deps) do
    for {implementation, behaviour} <- [
          {deps.repository, Ports.Repository},
          {deps.provider, Ports.Provider}
        ] do
      Code.ensure_loaded!(implementation)

      unless behaviour in (implementation.module_info(:attributes)[:behaviour] || []),
        do:
          raise(ArgumentError, "#{inspect(implementation)} must implement #{inspect(behaviour)}")
    end

    :ok
  end
end
