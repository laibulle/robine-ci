defmodule Robine.Secrets.Dependencies do
  @moduledoc false
  alias Robine.Secrets.Ports

  @enforce_keys [:repository, :cipher, :clock, :id_generator]
  defstruct [:repository, :cipher, :clock, :id_generator]

  @type t :: %__MODULE__{
          repository: module(),
          cipher: module(),
          clock: module(),
          id_generator: module()
        }

  @spec validate!(t()) :: :ok
  def validate!(%__MODULE__{} = dependencies) do
    for {implementation, behaviour} <- [
          {dependencies.repository, Ports.Repository},
          {dependencies.cipher, Ports.Cipher}
        ] do
      Code.ensure_loaded!(implementation)

      unless behaviour in (implementation.module_info(:attributes)[:behaviour] || []) do
        raise ArgumentError, "#{inspect(implementation)} must implement #{inspect(behaviour)}"
      end
    end

    :ok
  end
end
