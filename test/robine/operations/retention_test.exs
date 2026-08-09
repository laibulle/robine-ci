defmodule Robine.Operations.RetentionTest do
  use Robine.DataCase, async: false

  alias Robine.Adapters.Persistence.Postgres.Schemas.{Artifact, CacheEntry, StorageGcCandidate}
  alias Robine.Adapters.Persistence.Postgres.StorageRetention
  alias Robine.Adapters.Storage.LocalBlobStore
  alias Robine.{Operations, Repo, Storage}
  alias Robine.Runtime.Dependencies

  defmodule IncompleteInventoryBlobStore do
    @behaviour Robine.Storage.Ports.BlobStore

    def put(_content), do: {:error, :unsupported}
    def put_stream(_content), do: {:error, :unsupported}
    def get(_blob_id, _digest), do: {:error, :unsupported}

    def delete(blob_id) do
      send(self(), {:unexpected_delete, blob_id})
      :ok
    end

    def inventory, do: {:error, :unavailable}

    def delete_temporary_before(cutoff) do
      send(self(), {:unexpected_temporary_delete, cutoff})
      {:ok, 0}
    end

    def health, do: {:error, :unavailable}
  end

  setup do
    previous = Application.fetch_env!(:robine, :retention)
    previous_root = Application.fetch_env!(:robine, :storage_root)
    storage_root = Path.join(System.tmp_dir!(), "robine-retention-#{Ecto.UUID.generate()}")

    Application.put_env(:robine, :retention,
      log_seconds: 60,
      gc_grace_seconds: 0,
      batch_size: 100
    )

    Application.put_env(:robine, :storage_root, storage_root)

    on_exit(fn ->
      Application.put_env(:robine, :retention, previous)
      Application.put_env(:robine, :storage_root, previous_root)
      File.rm_rf(storage_root)
    end)
  end

  test "prunes expired metadata and deletes an unreferenced blob" do
    context = admin_context()
    repository_id = Ecto.UUID.generate()

    assert {:ok, artifact} =
             Storage.upload_artifact(
               %{
                 repository_id: repository_id,
                 attempt_id: Ecto.UUID.generate(),
                 name: "expired.txt",
                 content: "expired-content",
                 retention_seconds: 60
               },
               context
             )

    expire(Artifact, artifact.id)
    assert {:ok, result} = Operations.prune_retention(%{}, context)
    assert result.artifacts_deleted == 1
    assert result.blobs_deleted == 1
    assert Repo.get(Artifact, artifact.id) == nil
    assert Repo.get(StorageGcCandidate, artifact.digest) == nil
    assert {:error, :not_found} = LocalBlobStore.get(artifact.digest, artifact.digest)
  end

  test "never deletes a content-addressed blob still referenced by live metadata" do
    context = admin_context()
    repository_id = Ecto.UUID.generate()

    assert {:ok, artifact} =
             Storage.upload_artifact(
               %{
                 repository_id: repository_id,
                 attempt_id: Ecto.UUID.generate(),
                 name: "shared.txt",
                 content: "shared-content",
                 retention_seconds: 60
               },
               context
             )

    assert {:ok, cache} =
             Storage.save_cache(
               %{repository_id: repository_id, key: "shared", content: "shared-content"},
               context
             )

    assert artifact.digest == cache.digest
    expire(Artifact, artifact.id)

    assert {:ok, %{artifacts_deleted: 1, blobs_deleted: 0}} =
             Operations.prune_retention(%{}, context)

    assert Repo.get_by(CacheEntry, repository_id: repository_id, key: "shared")
    assert {:ok, "shared-content"} = LocalBlobStore.get(cache.digest, cache.digest)
    assert :ok = LocalBlobStore.delete(cache.digest)
  end

  test "retention is administrator-only" do
    context = Dependencies.context(%{id: "viewer", role: :viewer}, "retention-forbidden")
    assert {:error, :forbidden} = Operations.prune_retention(%{}, context)
  end

  test "reconciles orphan and missing objects and emits physical storage metrics" do
    context = admin_context()
    repository_id = Ecto.UUID.generate()
    handler = "storage-reconciliation-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:robine, :storage, :reconciliation],
        fn event, measurements, metadata, _config ->
          send(parent, {:storage_reconciliation, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, orphan} = LocalBlobStore.put("orphan-content")

    assert {:ok, artifact} =
             Storage.upload_artifact(
               %{
                 repository_id: repository_id,
                 attempt_id: Ecto.UUID.generate(),
                 name: "missing.txt",
                 content: "missing-content"
               },
               context
             )

    assert :ok = LocalBlobStore.delete(artifact.digest)
    assert {:ok, result} = Operations.prune_retention(%{}, context)
    assert result.orphan_objects == 1
    assert result.missing_objects == 1
    assert result.physical_bytes == byte_size("orphan-content")
    assert result.logical_bytes == byte_size("missing-content")
    assert Repo.get!(StorageGcCandidate, orphan.digest)

    assert_receive {:storage_reconciliation, [:robine, :storage, :reconciliation], measurements,
                    %{}}

    assert measurements.orphan_objects == 1
    assert measurements.missing_objects == 1

    assert {:ok, %{blobs_deleted: 1}} = Operations.prune_retention(%{}, context)
    assert {:error, :not_found} = LocalBlobStore.get(orphan.digest, orphan.digest)
  end

  test "an incomplete inventory cannot stage or delete reconciliation garbage" do
    assert {:error, :unavailable} =
             StorageRetention.prune(
               DateTime.utc_now(),
               [log_seconds: 60, gc_grace_seconds: 0, batch_size: 100],
               IncompleteInventoryBlobStore
             )

    assert Repo.aggregate(StorageGcCandidate, :count) == 0
    refute_receive {:unexpected_delete, _blob_id}
    refute_receive {:unexpected_temporary_delete, _cutoff}
  end

  defp admin_context do
    Dependencies.context(%{id: "admin", role: :administrator}, "retention")
  end

  defp expire(schema, id) do
    schema
    |> Repo.get!(id)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()
  end
end
