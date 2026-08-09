defmodule Robine.Adapters.Storage.S3IntegrationTest do
  use ExUnit.Case, async: false

  alias Robine.Adapters.Storage.{ExAwsS3Client, S3BlobStore}
  alias Robine.TestSupport.PortContracts.BlobStoreContract
  alias Robine.TestSupport.MinioServer

  @moduletag :s3_integration

  setup_all do
    case System.cmd("docker", ["image", "inspect", MinioServer.image()], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _missing -> [skip: "the pinned MinIO integration image is not installed"]
    end
  end

  setup do
    previous = Application.get_env(:robine, :s3_blob_store)
    server = start_supervised!(MinioServer)
    endpoint = MinioServer.endpoint(server)
    spool_root = Path.join(System.tmp_dir!(), "robine-minio-spool-#{Ecto.UUID.generate()}")

    config = [
      client: ExAwsS3Client,
      endpoint: endpoint,
      region: "us-east-1",
      bucket: "robine-integration",
      prefix: "contract",
      allow_http_loopback: true,
      path_style: true,
      access_key_id: "robine-test-access",
      secret_access_key: "robine-test-secret-key",
      spool_root: spool_root,
      part_size: 5 * 1024 * 1024,
      multipart_concurrency: 2,
      part_timeout_ms: 30_000
    ]

    assert :ok = create_bucket(config)
    Application.put_env(:robine, :s3_blob_store, config)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:robine, :s3_blob_store, previous),
        else: Application.delete_env(:robine, :s3_blob_store)

      File.rm_rf(spool_root)
    end)

    :ok
  end

  test "the blob-store contract passes against multipart S3-compatible storage" do
    assert :ok = S3BlobStore.validate_configuration!()
    content = :binary.copy(<<0, 1, 2, 3>>, 1_500_000)
    assert :ok = BlobStoreContract.assert_contract(S3BlobStore, content)
  end

  test "a timed-out part aborts its real multipart upload" do
    config = Application.fetch_env!(:robine, :s3_blob_store)
    path = Path.join(Keyword.fetch!(config, :spool_root), "forced-timeout")
    File.mkdir_p!(Path.dirname(path))

    File.open!(path, [:write, :binary], fn file ->
      Enum.each(1..32, fn _index -> IO.binwrite(file, :binary.copy(<<42>>, 1_000_000)) end)
    end)

    key = "contract/objects/aa/#{String.duplicate("a", 64)}"
    timed_out = Keyword.put(config, :part_timeout_ms, 1)

    assert {:error, :unavailable} =
             ExAwsS3Client.put_file(path, key, String.duplicate("a", 64), 32_000_000, timed_out)

    assert {:ok, %{body: body}} =
             ExAws.S3.list_multipart_uploads(Keyword.fetch!(config, :bucket), prefix: key)
             |> ExAws.request(request_config(config))

    assert body[:uploads] in [nil, []]
  end

  test "inventory paginates more than one thousand content-addressed objects" do
    config = Application.fetch_env!(:robine, :s3_blob_store)
    bucket = Keyword.fetch!(config, :bucket)
    request_options = request_config(config)

    1..1_005
    |> Task.async_stream(
      fn index ->
        digest = :crypto.hash(:sha256, Integer.to_string(index)) |> Base.encode16(case: :lower)
        key = "contract/objects/#{binary_part(digest, 0, 2)}/#{digest}"
        ExAws.S3.put_object(bucket, key, "x") |> ExAws.request(request_options)
      end,
      max_concurrency: 32,
      timeout: 30_000
    )
    |> Enum.each(fn result -> assert match?({:ok, {:ok, _response}}, result) end)

    assert {:ok, %{objects: objects, unsafe: 0}} = S3BlobStore.inventory()
    assert length(objects) == 1_005
    assert Enum.all?(objects, &(&1.size == 1))
  end

  defp create_bucket(config) do
    case ExAws.S3.put_bucket(Keyword.fetch!(config, :bucket), "us-east-1")
         |> ExAws.request(request_config(config)) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_config(config) do
    endpoint = URI.parse(Keyword.fetch!(config, :endpoint))

    [
      region: Keyword.fetch!(config, :region),
      scheme: endpoint.scheme <> "://",
      host: endpoint.host,
      port: endpoint.port,
      virtual_host: false,
      access_key_id: Keyword.fetch!(config, :access_key_id),
      secret_access_key: Keyword.fetch!(config, :secret_access_key)
    ]
  end
end
