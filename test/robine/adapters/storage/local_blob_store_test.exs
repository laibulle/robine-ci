defmodule Robine.Adapters.Storage.LocalBlobStoreTest do
  use ExUnit.Case, async: false

  alias Robine.Adapters.Storage.LocalBlobStore

  test "writes content atomically by digest and verifies every read" do
    content = "blob-#{Ecto.UUID.generate()}"
    assert {:ok, metadata} = LocalBlobStore.put(content)
    assert metadata.size == byte_size(content)
    assert metadata.blob_id == metadata.digest
    assert {:ok, ^content} = LocalBlobStore.get(metadata.blob_id, metadata.digest)

    root = Application.fetch_env!(:robine, :storage_root)
    path = Path.join([root, "objects", binary_part(metadata.blob_id, 0, 2), metadata.blob_id])
    :ok = File.write(path, "tampered", [:binary])
    assert {:error, :digest_mismatch} = LocalBlobStore.get(metadata.blob_id, metadata.digest)
    assert :ok = LocalBlobStore.delete(metadata.blob_id)
    assert {:error, :not_found} = LocalBlobStore.get(metadata.blob_id, metadata.digest)
  end

  test "rejects path-like and malformed object identifiers" do
    assert {:error, :invalid_blob_id} = LocalBlobStore.get("../../etc/passwd", "digest")
    assert {:error, :invalid_blob_id} = LocalBlobStore.delete("not-a-digest")
  end
end
