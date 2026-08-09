defmodule Robine.Adapters.Persistence.Postgres.StorageRepository do
  @moduledoc false
  @behaviour Robine.Storage.Ports.Repository
  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    Artifact,
    Attempt,
    CacheEntry,
    Job,
    StorageGcCandidate
  }

  alias Robine.Repo

  @impl true
  def insert_artifact(artifact, quotas) do
    quota_transaction(artifact.repository_id, artifact.size, fn -> 0 end, quotas, fn ->
      artifact
      |> Map.from_struct()
      |> then(&Artifact.changeset(%Artifact{}, &1))
      |> Repo.insert()
      |> case do
        {:ok, _schema} -> :ok
        {:error, changeset} -> Repo.rollback({:artifact_persistence, changeset})
      end
    end)
  end

  defp quota_transaction(repository_id, added_bytes, replaced_bytes, quotas, operation) do
    case Repo.transaction(fn ->
           Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["robine:storage-quota"])

           instance_usage = logical_usage(nil)
           repository_usage = logical_usage(repository_id)
           delta = added_bytes - replaced_bytes.()

           cond do
             instance_usage + delta > quotas.instance_bytes ->
               quota_denial(:instance)
               Repo.rollback({:quota_exceeded, :instance, quotas.instance_bytes})

             repository_usage + delta > quotas.repository_bytes ->
               quota_denial(:repository)
               Repo.rollback({:quota_exceeded, :repository, quotas.repository_bytes})

             true ->
               operation.()
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp quota_denial(scope) do
    :telemetry.execute([:robine, :storage, :quota_denial], %{count: 1}, %{scope: scope})
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
  def get_dependency_artifact(pipeline_id, job_key, name) do
    case Repo.one(
           from artifact in Artifact,
             join: attempt in Attempt,
             on: attempt.id == artifact.attempt_id,
             join: job in Job,
             on: job.id == attempt.job_id,
             where:
               job.pipeline_id == ^pipeline_id and job.job_key == ^job_key and
                 attempt.status == :succeeded and artifact.name == ^name,
             order_by: [desc: attempt.number],
             limit: 1,
             select: artifact
         ) do
      nil -> {:error, :not_found}
      schema -> {:ok, artifact_domain(schema)}
    end
  end

  @impl true
  def upsert_cache(cache, quotas) do
    replaced_bytes = fn ->
      Repo.one(
        from entry in CacheEntry,
          where: entry.repository_id == ^cache.repository_id and entry.key == ^cache.key,
          select: entry.size
      ) || 0
    end

    quota_transaction(cache.repository_id, cache.size, replaced_bytes, quotas, fn ->
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
        {:error, changeset} -> Repo.rollback({:cache_persistence, changeset})
      end
    end)
  end

  defp logical_usage(nil) do
    sum_size(Artifact, nil) + sum_size(CacheEntry, nil)
  end

  defp logical_usage(repository_id) do
    sum_size(Artifact, repository_id) + sum_size(CacheEntry, repository_id)
  end

  defp sum_size(schema, nil) do
    Repo.one(from row in schema, select: coalesce(sum(row.size), 0)) |> integer_size()
  end

  defp sum_size(schema, repository_id) do
    Repo.one(
      from row in schema,
        where: row.repository_id == ^repository_id,
        select: coalesce(sum(row.size), 0)
    )
    |> integer_size()
  end

  defp integer_size(%Decimal{} = size), do: Decimal.to_integer(size)
  defp integer_size(size) when is_integer(size), do: size

  @impl true
  def stage_blob_gc(blob_id, not_before, now) do
    %StorageGcCandidate{blob_id: blob_id, not_before: not_before, inserted_at: now}
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:blob_id])
    |> case do
      {:ok, _candidate} -> :ok
      {:error, changeset} -> {:error, {:blob_gc_persistence, changeset}}
    end
  end

  @impl true
  def get_cache(repository_id, key) do
    started = System.monotonic_time()

    result =
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

    outcome = if match?({:ok, _cache}, result), do: :hit, else: :miss

    :telemetry.execute(
      [:robine, :storage, :cache, :request],
      %{count: 1},
      %{outcome: outcome}
    )

    :telemetry.execute(
      [:robine, :storage, :request],
      %{duration: System.monotonic_time() - started},
      %{operation: :cache_restore, outcome: outcome}
    )

    result
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

  defp artifact_domain(schema) do
    struct!(Robine.Storage.Domain.Artifact, Map.from_struct(schema) |> Map.drop([:__meta__]))
  end
end
