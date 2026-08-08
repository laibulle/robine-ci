defmodule Robine.Adapters.Persistence.Postgres.StorageRepository do
  @moduledoc false
  @behaviour Robine.Storage.Ports.Repository
  import Ecto.Query
  alias Robine.Adapters.Persistence.Postgres.Schemas.{Artifact, CacheEntry}
  alias Robine.Repo

  @impl true
  def insert_artifact(artifact) do
    artifact
    |> Map.from_struct()
    |> then(&Artifact.changeset(%Artifact{}, &1))
    |> Repo.insert()
    |> case do
      {:ok, _schema} -> :ok
      {:error, changeset} -> {:error, {:artifact_persistence, changeset}}
    end
  end

  @impl true
  def get_artifact(repository_id, artifact_id) do
    case Repo.one(
           from artifact in Artifact,
             where: artifact.repository_id == ^repository_id and artifact.id == ^artifact_id
         ) do
      nil ->
        {:error, :not_found}

      schema ->
        {:ok,
         struct!(Robine.Storage.Domain.Artifact, Map.from_struct(schema) |> Map.drop([:__meta__]))}
    end
  end

  @impl true
  def upsert_cache(cache) do
    attributes = Map.from_struct(cache)

    CacheEntry.changeset(%CacheEntry{}, attributes)
    |> Repo.insert(
      on_conflict: [
        set: [
          id: cache.id,
          blob_id: cache.blob_id,
          digest: cache.digest,
          size: cache.size,
          created_at: cache.created_at,
          expires_at: cache.expires_at,
          last_restored_at: nil
        ]
      ],
      conflict_target: [:repository_id, :key]
    )
    |> case do
      {:ok, _schema} -> :ok
      {:error, changeset} -> {:error, {:cache_persistence, changeset}}
    end
  end

  @impl true
  def get_cache(repository_id, key) do
    case Repo.one(
           from cache in CacheEntry,
             where: cache.repository_id == ^repository_id and cache.key == ^key
         ) do
      nil ->
        {:error, :not_found}

      schema ->
        {:ok,
         struct!(
           Robine.Storage.Domain.CacheEntry,
           Map.from_struct(schema) |> Map.drop([:__meta__])
         )}
    end
  end

  @impl true
  def touch_cache(id, restored_at) do
    case Repo.get(CacheEntry, id) do
      nil ->
        {:error, :not_found}

      schema ->
        schema
        |> Ecto.Changeset.change(last_restored_at: restored_at)
        |> Repo.update()
        |> normalize()
    end
  end

  defp normalize({:ok, _schema}), do: :ok
  defp normalize({:error, changeset}), do: {:error, {:cache_persistence, changeset}}
end
