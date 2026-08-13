defmodule Robine.Adapters.Storage.S3BlobStore do
  @moduledoc false
  @behaviour Robine.Storage.Ports.BlobStore

  alias Robine.Adapters.Storage.S3Client

  @blob_id ~r/\A[0-9a-f]{64}\z/
  @bucket ~r/\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/

  def validate_configuration! do
    options = config()
    endpoint = Keyword.fetch!(options, :endpoint) |> URI.parse()
    bucket = Keyword.fetch!(options, :bucket)
    prefix = Keyword.get(options, :prefix, "")
    implementation = Keyword.fetch!(options, :client)

    unless valid_endpoint?(endpoint, Keyword.get(options, :allow_http_loopback, false)),
      do: raise(ArgumentError, "S3 endpoint must use HTTPS or allowed loopback HTTP")

    unless is_binary(bucket) and Regex.match?(@bucket, bucket),
      do: raise(ArgumentError, "S3 bucket name is invalid")

    unless valid_prefix?(prefix), do: raise(ArgumentError, "S3 prefix is invalid")

    unless Keyword.get(options, :part_size, 5 * 1024 * 1024) >= 5 * 1024 * 1024,
      do: raise(ArgumentError, "S3 multipart part size must be at least 5 MiB")

    Code.ensure_loaded!(implementation)

    unless S3Client in (implementation.module_info(:attributes)[:behaviour] || []),
      do: raise(ArgumentError, "S3 client must implement the adapter contract")

    :ok
  end

  @impl true
  def put(content) when is_binary(content), do: put_stream([content])

  @impl true
  def put_stream(chunks) do
    temporary = temporary_path()

    try do
      with :ok <- File.mkdir_p(spool_root()),
           {:ok, digest, size} <- write_spool(temporary, chunks),
           :ok <- client().put_file(temporary, object_key(digest), digest, size, config()) do
        {:ok, %{blob_id: digest, digest: digest, size: size}}
      else
        {:error, reason} -> normalize_error(reason)
      end
    rescue
      error -> {:error, {:blob_stream, error.__struct__}}
    after
      _ = File.rm(temporary)
    end
  end

  @impl true
  def get(blob_id, expected_digest) when is_binary(blob_id) and is_binary(expected_digest) do
    with :ok <- validate_id(blob_id),
         {:ok, content} <- client().get(object_key(blob_id), config()),
         true <- sha256(content) == expected_digest do
      {:ok, content}
    else
      false -> {:error, :digest_mismatch}
      {:error, reason} -> normalize_error(reason)
    end
  end

  @impl true
  def delete(blob_id) do
    with :ok <- validate_id(blob_id),
         :ok <- client().delete(object_key(blob_id), config()) do
      :ok
    else
      {:error, :not_found} -> :ok
      {:error, reason} -> normalize_error(reason)
    end
  end

  @impl true
  def inventory do
    prefix = object_prefix()

    with {:ok, objects} <- client().inventory(prefix, config()) do
      {valid, unsafe} =
        Enum.reduce(objects, {[], 0}, fn object, {valid, unsafe} ->
          case blob_id_from_key(object.key) do
            {:ok, blob_id} -> {[%{blob_id: blob_id, size: object.size} | valid], unsafe}
            :error -> {valid, unsafe + 1}
          end
        end)

      {:ok, %{objects: Enum.reverse(valid), unsafe: unsafe}}
    else
      {:error, reason} -> normalize_error(reason)
    end
  end

  @impl true
  def delete_temporary_before(%DateTime{} = cutoff) do
    cutoff_unix = DateTime.to_unix(cutoff, :second)

    spool_root()
    |> Path.join("*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reduce_while({:ok, 0}, fn path, {:ok, count} ->
      case File.lstat(path, time: :posix) do
        {:ok, %File.Stat{type: :regular, mtime: modified}} when modified <= cutoff_unix ->
          case File.rm(path) do
            :ok -> {:cont, {:ok, count + 1}}
            {:error, :enoent} -> {:cont, {:ok, count}}
            {:error, reason} -> {:halt, {:error, {:temporary_delete, reason}}}
          end

        {:ok, _stat} ->
          {:cont, {:ok, count}}

        {:error, :enoent} ->
          {:cont, {:ok, count}}

        {:error, reason} ->
          {:halt, {:error, {:temporary_stat, reason}}}
      end
    end)
  end

  @impl true
  def health do
    with :ok <- validate_configuration!(),
         :ok <- client().health(config()) do
      {:ok, %{backend: :s3, detail: "S3-compatible bucket reachable"}}
    else
      {:error, reason} -> normalize_error(reason)
    end
  rescue
    _error -> {:error, :invalid_configuration}
  end

  defp write_spool(path, chunks) do
    max_bytes = Application.fetch_env!(:robine, :storage_max_object_bytes)

    case File.open(path, [:write, :binary, :exclusive], fn file ->
           Enum.reduce_while(chunks, {:ok, :crypto.hash_init(:sha256), 0}, fn
             chunk, {:ok, hash, size} when is_binary(chunk) ->
               next_size = size + byte_size(chunk)

               if next_size <= max_bytes do
                 :ok = IO.binwrite(file, chunk)
                 {:cont, {:ok, :crypto.hash_update(hash, chunk), next_size}}
               else
                 {:halt, {:error, :object_too_large}}
               end

             _invalid, _state ->
               {:halt, {:error, :invalid_chunk}}
           end)
         end) do
      {:ok, {:ok, hash, size}} ->
        {:ok, :crypto.hash_final(hash) |> Base.encode16(case: :lower), size}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:spool_write, reason}}
    end
  end

  defp blob_id_from_key(key) do
    prefix = object_prefix()

    case String.replace_prefix(key, prefix, "") do
      <<shard::binary-size(2), "/", blob_id::binary-size(64)>> ->
        if validate_id(blob_id) == :ok and shard == binary_part(blob_id, 0, 2),
          do: {:ok, blob_id},
          else: :error

      _invalid ->
        :error
    end
  end

  defp object_key(blob_id), do: object_prefix() <> binary_part(blob_id, 0, 2) <> "/" <> blob_id

  defp object_prefix do
    config()
    |> Keyword.get(:prefix, "")
    |> Robine.Runtime.TenantStorage.object_prefix()
  end

  defp validate_id(blob_id),
    do: if(Regex.match?(@blob_id, blob_id), do: :ok, else: {:error, :invalid_blob_id})

  defp normalize_error(reason)
       when reason in [
              :not_found,
              :digest_mismatch,
              :object_too_large,
              :invalid_chunk,
              :invalid_blob_id,
              :forbidden,
              :throttled,
              :unavailable
            ],
       do: {:error, reason}

  defp normalize_error(reason), do: {:error, {:s3_blob_store, reason}}

  defp valid_endpoint?(%URI{scheme: "https"} = endpoint, _allowed),
    do: unambiguous_endpoint?(endpoint)

  defp valid_endpoint?(%URI{scheme: "http", host: host} = endpoint, true),
    do: host in ["localhost", "127.0.0.1", "::1"] and unambiguous_endpoint?(endpoint)

  defp valid_endpoint?(_endpoint, _allowed), do: false

  defp unambiguous_endpoint?(%URI{} = endpoint) do
    is_binary(endpoint.host) and endpoint.host != "" and endpoint.userinfo == nil and
      endpoint.query == nil and endpoint.fragment == nil and endpoint.path in [nil, "", "/"]
  end

  defp valid_prefix?(prefix) when is_binary(prefix) do
    normalized = String.trim(prefix, "/")
    normalized == prefix and not String.contains?(prefix, ["..", "//", "\\"])
  end

  defp valid_prefix?(_prefix), do: false
  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  defp temporary_path, do: Path.join(spool_root(), Ecto.UUID.generate())

  defp spool_root do
    config()
    |> Keyword.fetch!(:spool_root)
    |> Robine.Runtime.TenantStorage.local_root()
  end

  defp client, do: Keyword.fetch!(config(), :client)
  defp config, do: Application.fetch_env!(:robine, :s3_blob_store)
end
