defmodule Robine.Adapters.Storage.ExAwsS3Client do
  @moduledoc false
  @behaviour Robine.Adapters.Storage.S3Client

  alias ExAws.S3
  alias ExAws.S3.Upload

  @impl true
  def put_file(path, key, digest, _size, config) do
    bucket = Keyword.fetch!(config, :bucket)
    request_config = request_config(config)

    upload_options =
      [
        max_concurrency: Keyword.get(config, :multipart_concurrency, 2),
        timeout: Keyword.get(config, :part_timeout_ms, 60_000),
        refetch_auth_on_request: true,
        meta: [{"robine-sha256", digest}]
      ]
      |> maybe_encryption(config)

    upload =
      path
      |> Upload.stream_file(chunk_size: Keyword.get(config, :part_size, 5 * 1024 * 1024))
      |> S3.upload(bucket, key, upload_options)

    multipart_upload(upload, request_config)
  end

  @impl true
  def get(key, config) do
    bucket = Keyword.fetch!(config, :bucket)
    request_config = request_config(config)

    with {:ok, _metadata} <- S3.head_object(bucket, key) |> ExAws.request(request_config),
         {:ok, %{body: body}} when is_binary(body) <-
           S3.get_object(bucket, key) |> ExAws.request(request_config) do
      {:ok, body}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
      _invalid -> {:error, :invalid_response}
    end
  end

  @impl true
  def delete(key, config) do
    case S3.delete_object(Keyword.fetch!(config, :bucket), key)
         |> ExAws.request(request_config(config)) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl true
  def inventory(prefix, config) do
    try do
      objects =
        S3.list_objects_v2(Keyword.fetch!(config, :bucket), prefix: prefix)
        |> ExAws.stream!(request_config(config))
        |> Enum.map(fn object -> %{key: object.key, size: normalize_size(object.size)} end)

      {:ok, objects}
    rescue
      _error -> {:error, :inventory_unavailable}
    end
  end

  @impl true
  def health(config) do
    case S3.head_bucket(Keyword.fetch!(config, :bucket))
         |> ExAws.request(request_config(config)) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp multipart_upload(upload, request_config) do
    with {:ok, initialized} <- Upload.initialize(upload, request_config) do
      result = upload_parts(initialized, request_config)

      case result do
        {:ok, parts} ->
          case Upload.complete(parts, initialized, request_config) do
            {:ok, _response} -> :ok
            {:error, reason} -> abort(initialized, request_config, reason)
          end

        {:error, reason} ->
          abort(initialized, request_config, reason)
      end
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp upload_parts(upload, request_config) do
    upload.src
    |> Stream.with_index(1)
    |> Task.async_stream(
      fn part -> Upload.upload_chunk(part, %{upload | src: nil}, request_config) end,
      max_concurrency: Keyword.get(upload.opts, :max_concurrency, 2),
      timeout: Keyword.get(upload.opts, :timeout, 60_000),
      ordered: true,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {part_number, etag}}, {:ok, parts} ->
        {:cont, {:ok, [{part_number, etag} | parts]}}

      {:ok, {:error, reason}}, _parts ->
        {:halt, {:error, reason}}

      {:exit, _reason}, _parts ->
        {:halt, {:error, :part_timeout}}
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  rescue
    _error -> {:error, :multipart_failed}
  end

  defp abort(upload, request_config, reason) do
    _ =
      S3.abort_multipart_upload(upload.bucket, upload.path, upload.upload_id)
      |> ExAws.request(request_config)

    {:error, normalize_error(reason)}
  end

  defp request_config(config) do
    endpoint = Keyword.fetch!(config, :endpoint) |> URI.parse()

    [
      region: Keyword.fetch!(config, :region),
      scheme: endpoint.scheme <> "://",
      host: endpoint.host,
      port: endpoint.port,
      virtual_host: not Keyword.get(config, :path_style, false),
      access_key_id: Keyword.get(config, :access_key_id),
      secret_access_key: Keyword.get(config, :secret_access_key),
      security_token: Keyword.get(config, :security_token)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp normalize_error({:http_error, 404, _body}), do: :not_found
  defp normalize_error({:http_error, 403, _body}), do: :forbidden
  defp normalize_error({:http_error, 429, _body}), do: :throttled
  defp normalize_error({:http_error, status, _body}) when status >= 500, do: :unavailable

  defp normalize_error(%ExAws.Error{message: message}) when is_binary(message),
    do: :provider_error

  defp normalize_error(reason) when reason in [:timeout, :part_timeout], do: :unavailable
  defp normalize_error(_reason), do: :provider_error

  defp normalize_size(size) when is_integer(size), do: size
  defp normalize_size(size) when is_binary(size), do: String.to_integer(size)

  defp maybe_encryption(options, config) do
    case Keyword.get(config, :encryption) do
      nil -> options
      encryption -> Keyword.put(options, :encryption, encryption)
    end
  end
end
