defmodule Robine.Adapters.Persistence.Postgres.StorageRetention do
  @moduledoc false
  @behaviour Robine.Operations.Ports.Retention

  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    Artifact,
    CacheEntry,
    LogChunk,
    StorageGcCandidate
  }

  alias Robine.Adapters.Storage.LocalBlobStore
  alias Robine.Repo

  @impl true
  def prune(now, options) do
    batch_size = Keyword.fetch!(options, :batch_size)
    grace_seconds = Keyword.fetch!(options, :gc_grace_seconds)
    log_seconds = Keyword.fetch!(options, :log_seconds)

    with {:ok, staged} <- stage(now, batch_size, grace_seconds, log_seconds),
         {:ok, garbage} <- drain(now, batch_size) do
      {:ok, Map.put(staged, :blobs_deleted, garbage)}
    end
  end

  defp stage(now, batch_size, grace_seconds, log_seconds) do
    Repo.transaction(fn ->
      artifact_ids = expired_ids(Artifact, now, batch_size)
      cache_ids = expired_ids(CacheEntry, now, batch_size)
      blob_ids = blobs_for(Artifact, artifact_ids) ++ blobs_for(CacheEntry, cache_ids)

      {artifacts, _} = delete_ids(Artifact, artifact_ids)
      {caches, _} = delete_ids(CacheEntry, cache_ids)
      logs = delete_old_logs(DateTime.add(now, -log_seconds, :second), batch_size)
      stage_blobs(blob_ids, DateTime.add(now, grace_seconds, :second), now)

      %{artifacts_deleted: artifacts, caches_deleted: caches, logs_deleted: logs}
    end)
  end

  defp expired_ids(schema, now, limit) do
    Repo.all(
      from row in schema,
        where: row.expires_at <= ^now,
        order_by: row.expires_at,
        limit: ^limit,
        select: row.id
    )
  end

  defp blobs_for(_schema, []), do: []

  defp blobs_for(schema, ids) do
    Repo.all(from row in schema, where: row.id in ^ids, select: row.blob_id)
  end

  defp delete_ids(_schema, []), do: {0, nil}
  defp delete_ids(schema, ids), do: Repo.delete_all(from row in schema, where: row.id in ^ids)

  defp delete_old_logs(cutoff, limit) do
    ids =
      Repo.all(
        from row in LogChunk,
          where: row.inserted_at <= ^cutoff,
          order_by: row.inserted_at,
          limit: ^limit,
          select: row.id
      )

    {count, _} = delete_ids(LogChunk, ids)
    count
  end

  defp stage_blobs(blob_ids, not_before, now) do
    rows =
      blob_ids
      |> Enum.uniq()
      |> Enum.map(&%{blob_id: &1, not_before: not_before, inserted_at: now})

    Repo.insert_all(StorageGcCandidate, rows,
      on_conflict: :nothing,
      conflict_target: [:blob_id]
    )
  end

  defp drain(now, limit) do
    candidates =
      Repo.all(
        from candidate in StorageGcCandidate,
          where: candidate.not_before <= ^now,
          order_by: candidate.not_before,
          limit: ^limit
      )

    Enum.reduce_while(candidates, {:ok, 0}, fn candidate, {:ok, count} ->
      if referenced?(candidate.blob_id) do
        acknowledge(candidate.blob_id)
        {:cont, {:ok, count}}
      else
        case LocalBlobStore.delete(candidate.blob_id) do
          :ok ->
            acknowledge(candidate.blob_id)
            {:cont, {:ok, count + 1}}

          {:error, reason} ->
            {:halt, {:error, {:blob_gc, reason}}}
        end
      end
    end)
  end

  defp referenced?(blob_id) do
    Repo.exists?(from artifact in Artifact, where: artifact.blob_id == ^blob_id) or
      Repo.exists?(from cache in CacheEntry, where: cache.blob_id == ^blob_id)
  end

  defp acknowledge(blob_id) do
    Repo.delete_all(from candidate in StorageGcCandidate, where: candidate.blob_id == ^blob_id)
  end
end
