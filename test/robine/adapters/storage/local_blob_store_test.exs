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

  test "streams to a hidden temporary file and publishes only after completion" do
    parent = self()
    first = "streamed-"
    second = "content-#{Ecto.UUID.generate()}"
    content = first <> second
    digest = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    stream =
      Stream.map([first, second], fn
        ^first ->
          send(parent, :first_chunk)
          first

        ^second ->
          send(parent, :waiting_for_final_chunk)

          receive do
            :continue_stream -> second
          end
      end)

    task = Task.async(fn -> LocalBlobStore.put_stream(stream) end)
    assert_receive :first_chunk
    assert_receive :waiting_for_final_chunk
    refute File.exists?(object_path(digest))

    send(task.pid, :continue_stream)
    assert {:ok, %{blob_id: ^digest, size: size}} = Task.await(task)
    assert size == byte_size(content)
    assert {:ok, ^content} = LocalBlobStore.get(digest, digest)
    assert :ok = LocalBlobStore.delete(digest)
  end

  test "removes incomplete temporary objects and stops at the configured limit" do
    previous = Application.fetch_env!(:robine, :storage_max_object_bytes)
    Application.put_env(:robine, :storage_max_object_bytes, 5)
    on_exit(fn -> Application.put_env(:robine, :storage_max_object_bytes, previous) end)

    temporary_before = temporary_entries()
    parent = self()

    stream =
      ["123", "456", "must-not-run"]
      |> Stream.map(fn chunk ->
        send(parent, {:enumerated, chunk})
        chunk
      end)

    assert {:error, :object_too_large} = LocalBlobStore.put_stream(stream)
    assert_receive {:enumerated, "123"}
    assert_receive {:enumerated, "456"}
    refute_receive {:enumerated, "must-not-run"}
    assert temporary_entries() == temporary_before

    assert {:error, :invalid_chunk} = LocalBlobStore.put_stream(["part", nil])
    assert temporary_entries() == temporary_before

    exploding =
      Stream.map(["secret-fixture-content"], fn _chunk -> raise "secret-fixture-content" end)

    assert {:error, {:blob_stream, RuntimeError}} = LocalBlobStore.put_stream(exploding)
    refute inspect(LocalBlobStore.put_stream(exploding)) =~ "secret-fixture-content"
    assert temporary_entries() == temporary_before
  end

  defp object_path(blob_id) do
    root = Application.fetch_env!(:robine, :storage_root)
    Path.join([root, "objects", binary_part(blob_id, 0, 2), blob_id])
  end

  defp temporary_entries do
    root = Application.fetch_env!(:robine, :storage_root)

    case File.ls(Path.join(root, ".tmp")) do
      {:ok, entries} -> Enum.sort(entries)
      {:error, :enoent} -> []
    end
  end
end
