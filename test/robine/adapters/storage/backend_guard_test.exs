defmodule Robine.Adapters.Storage.BackendGuardTest do
  use Robine.DataCase, async: false

  alias Robine.Adapters.Persistence.Postgres.Schemas.{Artifact, StorageBackendState}
  alias Robine.Adapters.Storage.{BackendGuard, LocalBlobStore, S3BlobStore}

  setup do
    previous = %{
      blob_store_adapter: Application.get_env(:robine, :blob_store_adapter),
      storage_root: Application.get_env(:robine, :storage_root),
      s3_blob_store: Application.get_env(:robine, :s3_blob_store),
      migration_ack: Application.get_env(:robine, :storage_backend_migration_ack)
    }

    Application.put_env(:robine, :blob_store_adapter, LocalBlobStore)
    Application.put_env(:robine, :storage_root, "/var/lib/robine-test/blobs")
    Application.delete_env(:robine, :storage_backend_migration_ack)
    Repo.delete_all(StorageBackendState)

    on_exit(fn ->
      restore_env(:blob_store_adapter, previous.blob_store_adapter)
      restore_env(:storage_root, previous.storage_root)
      restore_env(:s3_blob_store, previous.s3_blob_store)
      restore_env(:storage_backend_migration_ack, previous.migration_ack)
    end)

    :ok
  end

  test "records a fresh backend and remains idempotent" do
    assert :ok = BackendGuard.verify()
    assert :ok = BackendGuard.verify()

    assert %StorageBackendState{
             id: "primary",
             backend: "local",
             acknowledged_at: nil
           } = Repo.get!(StorageBackendState, "primary")
  end

  test "safely records the formerly implicit local backend when metadata exists" do
    insert_artifact()

    assert :ok = BackendGuard.verify()
    assert %{backend: "local", acknowledged_at: nil} = Repo.get!(StorageBackendState, "primary")
  end

  test "rejects a backend change with retained metadata until the exact acknowledgement is supplied" do
    assert :ok = BackendGuard.verify()
    previous_digest = Repo.get!(StorageBackendState, "primary").namespace_digest
    insert_artifact()
    configure_s3()

    assert {:error, {:storage_backend_migration_ack_required, expected}} = BackendGuard.verify()
    assert expected != BackendGuard.transition_ack(previous_digest, previous_digest)

    assert %{backend: "local", namespace_digest: ^previous_digest} =
             Repo.get!(StorageBackendState, "primary")

    Application.put_env(:robine, :storage_backend_migration_ack, "wrong")
    assert {:error, {:storage_backend_migration_ack_required, ^expected}} = BackendGuard.verify()

    Application.put_env(:robine, :storage_backend_migration_ack, expected)
    assert :ok = BackendGuard.verify()

    assert %{backend: "s3", acknowledged_at: %DateTime{}} =
             Repo.get!(StorageBackendState, "primary")
  end

  test "automatically updates the recorded backend when no retained metadata can be orphaned" do
    assert :ok = BackendGuard.verify()
    configure_s3()

    assert :ok = BackendGuard.verify()

    assert %{backend: "s3", acknowledged_at: nil} =
             Repo.get!(StorageBackendState, "primary")
  end

  test "requires acknowledgement when a non-local backend is first recorded over existing metadata" do
    insert_artifact()
    configure_s3()

    assert {:error, {:storage_backend_migration_ack_required, expected}} = BackendGuard.verify()
    refute Repo.get(StorageBackendState, "primary")

    Application.put_env(:robine, :storage_backend_migration_ack, expected)
    assert :ok = BackendGuard.verify()

    assert %{backend: "s3", acknowledged_at: %DateTime{}} =
             Repo.get!(StorageBackendState, "primary")
  end

  defp configure_s3 do
    Application.put_env(:robine, :blob_store_adapter, S3BlobStore)

    Application.put_env(:robine, :s3_blob_store,
      endpoint: "https://objects.example.test/",
      bucket: "robine-ci",
      prefix: "/primary/"
    )
  end

  defp insert_artifact do
    now = DateTime.utc_now()

    %Artifact{}
    |> Artifact.changeset(%{
      id: Ecto.UUID.generate(),
      repository_id: Ecto.UUID.generate(),
      attempt_id: Ecto.UUID.generate(),
      name: "retained",
      blob_id: String.duplicate("a", 64),
      digest: String.duplicate("a", 64),
      size: 1,
      created_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
    |> Repo.insert!()
  end

  defp restore_env(key, nil), do: Application.delete_env(:robine, key)
  defp restore_env(key, value), do: Application.put_env(:robine, key, value)
end
