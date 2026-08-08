defmodule Robine.Storage.Dependencies do
  @moduledoc false
  alias Robine.Storage.Ports
  @enforce_keys [:repository, :blob_store, :clock, :id_generator]
  defstruct [:repository, :blob_store, :clock, :id_generator]

  @type t :: %__MODULE__{
          repository: module(),
          blob_store: module(),
          clock: module(),
          id_generator: module()
        }

  @spec validate!(t()) :: :ok
  def validate!(%__MODULE__{} = dependencies) do
    for {implementation, behaviour} <- [
          {dependencies.repository, Ports.Repository},
          {dependencies.blob_store, Ports.BlobStore}
        ] do
      Code.ensure_loaded!(implementation)

      unless behaviour in (implementation.module_info(:attributes)[:behaviour] || []),
        do:
          raise(ArgumentError, "#{inspect(implementation)} must implement #{inspect(behaviour)}")
    end

    :ok
  end
end
