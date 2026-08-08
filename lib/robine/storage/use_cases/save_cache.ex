defmodule Robine.Storage.UseCases.SaveCache do
  @moduledoc "Atomically publishes one complete exact-key cache entry."
  alias Robine.ExecutionContext
  alias Robine.Storage.Contracts.CacheMetadata
  alias Robine.Storage.Dependencies
  alias Robine.Storage.Domain.CacheEntry

  @spec call(map(), ExecutionContext.t()) :: {:ok, CacheMetadata.t()} | {:error, term()}
  def call(input, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{storage: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer] do
    with {:ok, values} <- validate(input),
         {:ok, blob} <- deps.blob_store.put(values.content),
         now = DateTime.truncate(deps.clock.now(), :microsecond),
         cache = %CacheEntry{
           id: deps.id_generator.generate(),
           repository_id: values.repository_id,
           key: values.key,
           blob_id: blob.blob_id,
           digest: blob.digest,
           size: blob.size,
           created_at: now,
           expires_at: DateTime.add(now, values.retention_seconds, :second),
           last_restored_at: nil
         },
         :ok <- deps.repository.upsert_cache(cache) do
      {:ok,
       struct!(
         CacheMetadata,
         Map.take(Map.from_struct(cache), [:key, :digest, :size, :created_at, :expires_at])
       )}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp validate(input) do
    values = %{
      repository_id: Map.get(input, :repository_id),
      key: Map.get(input, :key),
      content: Map.get(input, :content),
      retention_seconds: Map.get(input, :retention_seconds, 604_800)
    }

    cond do
      not is_binary(values.repository_id) ->
        {:error, {:invalid_cache, :repository_id}}

      not (is_binary(values.key) and byte_size(values.key) in 1..512) ->
        {:error, {:invalid_cache, :key}}

      not is_binary(values.content) ->
        {:error, {:invalid_cache, :content}}

      not (is_integer(values.retention_seconds) and values.retention_seconds > 0) ->
        {:error, {:invalid_cache, :retention}}

      true ->
        {:ok, values}
    end
  end
end
