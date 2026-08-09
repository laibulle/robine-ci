defmodule Robine.Adapters.Storage.S3BlobStoreTest do
  use ExUnit.Case, async: false

  alias Robine.Adapters.Storage.S3BlobStore
  alias Robine.TestSupport.FakeS3Client

  setup do
    previous = Application.get_env(:robine, :s3_blob_store)
    previous_limit = Application.fetch_env!(:robine, :storage_max_object_bytes)
    spool_root = Path.join(System.tmp_dir!(), "robine-s3-spool-#{Ecto.UUID.generate()}")
    store = start_supervised!({Agent, fn -> %{} end}, id: :fake_s3_store)

    config = [
      client: FakeS3Client,
      fake_owner: self(),
      fake_store: store,
      endpoint: "https://s3.example.test",
      region: "us-east-1",
      bucket: "test",
      prefix: "tenant-a",
      spool_root: spool_root
    ]

    Application.put_env(:robine, :s3_blob_store, config)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:robine, :s3_blob_store, previous),
        else: Application.delete_env(:robine, :s3_blob_store)

      Application.put_env(:robine, :storage_max_object_bytes, previous_limit)
      File.rm_rf(spool_root)
    end)

    {:ok, config: config, store: store, spool_root: spool_root}
  end

  test "spools a stream, publishes by digest, verifies reads, and deletes idempotently", %{
    spool_root: spool_root
  } do
    content = "bounded-" <> String.duplicate("stream", 1_000)

    assert {:ok, metadata} =
             S3BlobStore.put_stream(["bounded-", String.duplicate("stream", 1_000)])

    assert_receive {:s3_put, temporary, key, digest, size}
    assert digest == metadata.digest
    assert size == byte_size(content)
    assert key == "tenant-a/objects/#{binary_part(digest, 0, 2)}/#{digest}"
    refute File.exists?(temporary)
    assert Path.dirname(temporary) == spool_root
    assert {:ok, ^content} = S3BlobStore.get(metadata.blob_id, metadata.digest)
    assert :ok = S3BlobStore.delete(metadata.blob_id)
    assert :ok = S3BlobStore.delete(metadata.blob_id)
    assert {:error, :not_found} = S3BlobStore.get(metadata.blob_id, metadata.digest)
  end

  test "rejects invalid streams and removes spools after provider failures", %{config: config} do
    assert {:error, :invalid_chunk} = S3BlobStore.put_stream(["valid", nil])
    assert File.ls!(Keyword.fetch!(config, :spool_root)) == []

    Application.put_env(:robine, :s3_blob_store, Keyword.put(config, :put_error, :throttled))
    assert {:error, :throttled} = S3BlobStore.put("content")
    assert File.ls!(Keyword.fetch!(config, :spool_root)) == []
  end

  test "enforces the object limit and reports malformed in-prefix inventory", %{
    config: config,
    store: store
  } do
    Application.put_env(:robine, :storage_max_object_bytes, 4)
    assert {:error, :object_too_large} = S3BlobStore.put_stream(["12", "345"])

    digest = :crypto.hash(:sha256, "ok") |> Base.encode16(case: :lower)
    valid_key = "tenant-a/objects/#{binary_part(digest, 0, 2)}/#{digest}"

    Agent.update(store, fn _state ->
      %{valid_key => "ok", "tenant-a/objects/not-safe" => "bad", "another/prefix" => "ignored"}
    end)

    assert {:ok, %{objects: [%{blob_id: ^digest, size: 2}], unsafe: 1}} =
             S3BlobStore.inventory()

    assert {:error, :invalid_blob_id} = S3BlobStore.delete("../../bucket")
    assert Keyword.fetch!(config, :client) == FakeS3Client
  end

  test "validates secure endpoints and bounded multipart configuration", %{config: config} do
    assert :ok = S3BlobStore.validate_configuration!()

    for invalid_endpoint <- [
          "http://s3.example.test",
          "https://access:secret@s3.example.test",
          "https://s3.example.test/path",
          "https://s3.example.test?bucket=other",
          "https://s3.example.test#fragment"
        ] do
      Application.put_env(
        :robine,
        :s3_blob_store,
        Keyword.put(config, :endpoint, invalid_endpoint)
      )

      assert_raise ArgumentError, ~r/must use HTTPS/, fn ->
        S3BlobStore.validate_configuration!()
      end
    end

    Application.put_env(
      :robine,
      :s3_blob_store,
      config
      |> Keyword.put(:endpoint, "http://127.0.0.1:9000")
      |> Keyword.put(:allow_http_loopback, true)
      |> Keyword.put(:part_size, 1024)
    )

    assert_raise ArgumentError, ~r/at least 5 MiB/, fn ->
      S3BlobStore.validate_configuration!()
    end
  end

  test "normalizes provider failures and detects corrupt object content", %{
    config: config,
    store: store
  } do
    for reason <- [:forbidden, :throttled, :unavailable] do
      Application.put_env(:robine, :s3_blob_store, Keyword.put(config, :get_error, reason))

      assert {:error, ^reason} =
               S3BlobStore.get(String.duplicate("a", 64), String.duplicate("a", 64))
    end

    Application.put_env(:robine, :s3_blob_store, config)
    assert {:ok, metadata} = S3BlobStore.put("original")
    assert_receive {:s3_put, _temporary, key, _digest, _size}
    Agent.update(store, &Map.put(&1, key, "corrupt"))
    assert {:error, :digest_mismatch} = S3BlobStore.get(metadata.blob_id, metadata.digest)

    Application.put_env(
      :robine,
      :s3_blob_store,
      Keyword.put(config, :inventory_error, :unavailable)
    )

    assert {:error, :unavailable} = S3BlobStore.inventory()
  end

  test "a large lazy stream stays inside a bounded process-memory envelope", %{config: config} do
    Application.put_env(
      :robine,
      :s3_blob_store,
      Keyword.put(config, :record_only, true)
    )

    owner = self()

    stream =
      Stream.map(1..64, fn index ->
        chunk = :binary.copy(<<rem(index, 251)>>, 1_000_000)
        send(owner, {:stream_chunk, index, self()})

        receive do
          :continue_stream -> chunk
        end
      end)

    task = Task.async(fn -> S3BlobStore.put_stream(stream) end)

    peak_bytes =
      Enum.reduce(1..64, 0, fn index, peak ->
        assert_receive {:stream_chunk, ^index, producer}, 5_000
        memory = process_memory(task.pid)
        send(producer, :continue_stream)
        max(peak, memory)
      end)

    assert {:ok, %{size: 64_000_000}} = Task.await(task, 20_000)
    assert peak_bytes < 16_000_000
  end

  defp process_memory(pid) do
    {:memory, heap_bytes} = Process.info(pid, :memory)
    {:binary, binaries} = Process.info(pid, :binary)

    heap_bytes +
      Enum.reduce(binaries, 0, fn {_reference, size, _references}, total -> total + size end)
  end
end
