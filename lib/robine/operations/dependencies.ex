defmodule Robine.Operations.Dependencies do
  @moduledoc false
  alias Robine.Operations.Ports.{Health, Retention}
  alias Robine.Storage.Ports.BlobStore
  @enforce_keys [:health, :retention, :blob_store]
  defstruct [:health, :retention, :blob_store]
  @type t :: %__MODULE__{health: module(), retention: module(), blob_store: module()}

  def validate!(%__MODULE__{} = dependencies) do
    for {implementation, behaviour} <- [
          {dependencies.health, Health},
          {dependencies.retention, Retention},
          {dependencies.blob_store, BlobStore}
        ] do
      Code.ensure_loaded!(implementation)

      unless behaviour in (implementation.module_info(:attributes)[:behaviour] || []),
        do:
          raise(ArgumentError, "#{inspect(implementation)} must implement #{inspect(behaviour)}")
    end

    :ok
  end
end
