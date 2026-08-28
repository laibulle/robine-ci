defmodule Robine.Storage.UseCases.RestoreCache do
  @moduledoc "Restores the newest complete exact-key cache entry or reports a safe miss."
  alias Robine.ExecutionContext
  alias Robine.Storage.Contracts.Download
  alias Robine.Storage.Dependencies

  @spec call(map(), ExecutionContext.t()) :: {:ok, Download.t() | :miss} | {:error, term()}
  def call(%{repository_id: repository_id, key: key}, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{storage: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer, :viewer] and is_binary(repository_id) and
             is_binary(key) do
    case deps.repository.get_cache(repository_id, key) do
      {:ok, cache} -> restore(cache, deps)
      {:error, :not_found} -> {:ok, :miss}
      error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp restore(cache, deps) do
    if DateTime.compare(cache.expires_at, deps.clock.now()) == :gt do
      with {:ok, content} <- deps.blob_store.get(cache.blob_id, cache.digest),
           :ok <- deps.repository.touch_cache(cache.id, deps.clock.now()) do
        {:ok,
         %Download{
           name: cache.key,
           content_type: "application/gzip",
           digest: cache.digest,
           size: cache.size,
           content: content
         }}
      end
    else
      {:ok, :miss}
    end
  end
end
