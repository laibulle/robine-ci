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
         {:ok, garbage} <- drain(now, batch_size),
         {:ok, reconciliation} <- reconcile(now, batch_size, grace_seconds) do
      {:ok, staged |> Map.put(:blobs_deleted, garbage) |> Map.merge(reconciliation)}
    end
  end

  defp reconcile(now, batch_size, grace_seconds) do
    with {:ok, %{objects: objects, unsafe: unsafe}} <- LocalBlobStore.inventory(),
         {:ok, temporary_deleted} <-
           LocalBlobStore.delete_temporary_before(DateTime.add(now, -grace_seconds, :second)) do
      physical_ids = MapSet.new(objects, & &1.blob_id)
      referenced = referenced_blob_ids()
      referenced_ids = MapSet.new(referenced, & &1.blob_id)

      orphan_ids =
        physical_ids
        |> MapSet.difference(referenced_ids)

      missing = MapSet.difference(referenced_ids, physical_ids) |> MapSet.size()

      staged_orphans =
        stage_blobs(
          Enum.take(orphan_ids, batch_size),
          DateTime.add(now, grace_seconds, :second),
          now
        )

      logical_bytes = Enum.reduce(referenced, 0, &(&1.size + &2))
      physical_bytes = Enum.reduce(objects, 0, &(&1.size + &2))

      measurements = %{
        count: 1,
        logical_bytes: logical_bytes,
        physical_bytes: physical_bytes,
        orphan_objects: MapSet.size(orphan_ids),
        missing_objects: missing,
        unsafe_objects: unsafe,
        temporary_deleted: temporary_deleted
      }

      :telemetry.execute([:robine, :storage, :reconciliation], measurements, %{})
      {:ok, Map.put(measurements, :orphans_staged, staged_orphans)}
    end
  end

  defp referenced_blob_ids do
    Repo.all(from artifact in Artifact, select: %{blob_id: artifact.blob_id, size: artifact.size}) ++
      Repo.all(from cache in CacheEntry, select: %{blob_id: cache.blob_id, size: cache.size})
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

    {count, _result} =
      Repo.insert_all(StorageGcCandidate, rows,
        on_conflict: :nothing,
        conflict_target: [:blob_id]
      )

    count
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
