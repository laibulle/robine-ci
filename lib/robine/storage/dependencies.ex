defmodule Robine.Storage.Dependencies do
  @moduledoc false
  alias Robine.Storage.Ports

  @enforce_keys [
    :repository,
    :blob_store,
    :clock,
    :id_generator,
    :instance_quota_bytes,
    :repository_quota_bytes
  ]
  defstruct [
    :repository,
    :blob_store,
    :clock,
    :id_generator,
    :instance_quota_bytes,
    :repository_quota_bytes
  ]

  @type t :: %__MODULE__{
          repository: module(),
          blob_store: module(),
          clock: module(),
          id_generator: module(),
          instance_quota_bytes: pos_integer(),
          repository_quota_bytes: pos_integer()
        }

  @spec validate!(t()) :: :ok
  def validate!(%__MODULE__{} = dependencies) do
    unless is_integer(dependencies.instance_quota_bytes) and
             is_integer(dependencies.repository_quota_bytes) and
             dependencies.repository_quota_bytes > 0 and
             dependencies.repository_quota_bytes <= dependencies.instance_quota_bytes do
      raise ArgumentError,
            "storage quotas must be positive and repository quota must fit instance"
    end

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
