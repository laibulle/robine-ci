defmodule Robine.Operations.RetentionTest do
  use Robine.DataCase, async: false

  alias Robine.Adapters.Persistence.Postgres.Schemas.{Artifact, CacheEntry, StorageGcCandidate}
  alias Robine.Adapters.Storage.LocalBlobStore
  alias Robine.{Operations, Repo, Storage}
  alias Robine.Runtime.Dependencies

  setup do
    previous = Application.fetch_env!(:robine, :retention)

    Application.put_env(:robine, :retention,
      log_seconds: 60,
      gc_grace_seconds: 0,
      batch_size: 100
    )

    on_exit(fn -> Application.put_env(:robine, :retention, previous) end)
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
