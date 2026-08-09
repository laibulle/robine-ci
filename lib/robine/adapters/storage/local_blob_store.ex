defmodule Robine.Adapters.Storage.LocalBlobStore do
  @moduledoc false
  @behaviour Robine.Storage.Ports.BlobStore

  @blob_id ~r/\A[0-9a-f]{64}\z/

  @impl true
  def put(content) when is_binary(content), do: put_stream([content])

  @impl true
  def put_stream(chunks) do
    temporary = temporary_path()

    try do
      with :ok <- prepare_temporary_directory(),
           {:ok, digest, size} <- write_stream(temporary, chunks),
           target = object_path(digest),
           :ok <- prepare_object_directory(target),
           :ok <- publish(temporary, target) do
        :telemetry.execute(
          [:robine, :storage, :blob, :write],
          %{bytes: size, count: 1},
          %{outcome: :ok}
        )

        {:ok, %{blob_id: digest, digest: digest, size: size}}
      else
        {:error, reason} ->
          _ = File.rm(temporary)

          :telemetry.execute(
            [:robine, :storage, :blob, :write],
            %{bytes: 0, count: 1},
            %{outcome: error_outcome(reason)}
          )

          normalize_write_error(reason)
      end
    rescue
      error ->
        _ = File.rm(temporary)
        {:error, {:blob_stream, error.__struct__}}
    end
  end

  @impl true
  def get(blob_id, expected_digest) when is_binary(blob_id) and is_binary(expected_digest) do
    with :ok <- validate_id(blob_id),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(object_path(blob_id)),
         {:ok, content} <- File.read(object_path(blob_id)),
         true <- sha256(content) == expected_digest do
      {:ok, content}
    else
      {:error, :enoent} -> {:error, :not_found}
      false -> {:error, :digest_mismatch}
      {:ok, %File.Stat{}} -> {:error, :unsafe_object_type}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(blob_id) do
    with :ok <- validate_id(blob_id) do
      case File.rm(object_path(blob_id)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def inventory do
    paths = Path.wildcard(Path.join([root(), "objects", "*", "*"]), match_dot: true)

    {objects, unsafe} =
      Enum.reduce(paths, {[], 0}, fn path, {objects, unsafe} ->
        blob_id = Path.basename(path)
        shard = Path.basename(Path.dirname(path))

        case {validate_id(blob_id), File.lstat(path)} do
          {:ok, {:ok, %File.Stat{type: :regular, size: size}}}
          when shard == binary_part(blob_id, 0, 2) ->
            {[%{blob_id: blob_id, size: size} | objects], unsafe}

          _other ->
            {objects, unsafe + 1}
        end
      end)

    {:ok, %{objects: Enum.reverse(objects), unsafe: unsafe}}
  rescue
    error -> {:error, {:blob_inventory, error.__struct__}}
  end

  @impl true
  def delete_temporary_before(%DateTime{} = cutoff) do
    paths = Path.wildcard(Path.join([root(), ".tmp", "*"]), match_dot: true)
    cutoff_unix = DateTime.to_unix(cutoff, :second)

    Enum.reduce_while(paths, {:ok, 0}, fn path, {:ok, count} ->
      case File.lstat(path, time: :posix) do
        {:ok, %File.Stat{mtime: modified}} when modified <= cutoff_unix ->
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
    probe = Path.join(root(), ".health-#{Ecto.UUID.generate()}")

    try do
      with :ok <- File.mkdir_p(root()), :ok <- File.write(probe, "health", [:exclusive]) do
        {:ok, %{backend: :local, detail: "Local blob storage writable"}}
      else
        {:error, reason} -> {:error, {:local_storage, reason}}
      end
    after
      File.rm(probe)
    end
  rescue
    _error -> {:error, :local_storage_unavailable}
  end

  defp prepare_temporary_directory, do: File.mkdir_p(Path.join(root(), ".tmp"))
  defp prepare_object_directory(target), do: File.mkdir_p(Path.dirname(target))

  defp write_stream(temporary, chunks) do
    max_bytes = Application.fetch_env!(:robine, :storage_max_object_bytes)

    case File.open(temporary, [:write, :binary, :exclusive], fn file ->
           Enum.reduce_while(chunks, {:ok, :crypto.hash_init(:sha256), 0}, fn
             chunk, {:ok, hash, size} when is_binary(chunk) ->
               next_size = size + byte_size(chunk)

               cond do
                 next_size > max_bytes ->
                   {:halt, {:error, :object_too_large}}

                 true ->
                   :ok = IO.binwrite(file, chunk)
                   {:cont, {:ok, :crypto.hash_update(hash, chunk), next_size}}
               end

             _chunk, _state ->
               {:halt, {:error, :invalid_chunk}}
           end)
         end) do
      {:ok, {:ok, hash, size}} ->
        digest = :crypto.hash_final(hash) |> Base.encode16(case: :lower)
        {:ok, digest, size}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish(temporary, target) do
    case File.rename(temporary, target) do
      :ok -> :ok
      {:error, :eexist} -> File.rm(temporary)
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_write_error(:object_too_large), do: {:error, :object_too_large}
  defp normalize_write_error(:invalid_chunk), do: {:error, :invalid_chunk}
  defp normalize_write_error(reason), do: {:error, {:blob_write, reason}}

  defp error_outcome(:object_too_large), do: :too_large
  defp error_outcome(:invalid_chunk), do: :invalid_chunk
  defp error_outcome(_reason), do: :error

  defp validate_id(blob_id),
    do: if(Regex.match?(@blob_id, blob_id), do: :ok, else: {:error, :invalid_blob_id})

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp object_path(blob_id),
    do: Path.join([root(), "objects", binary_part(blob_id, 0, 2), blob_id])

  defp temporary_path, do: Path.join([root(), ".tmp", Ecto.UUID.generate()])
  defp root, do: Application.fetch_env!(:robine, :storage_root)
end
