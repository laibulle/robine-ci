defmodule Robine.Adapters.Storage.LocalBlobStore do
  @moduledoc false
  @behaviour Robine.Storage.Ports.BlobStore

  @blob_id ~r/\A[0-9a-f]{64}\z/

  @impl true
  def put(content) when is_binary(content) do
    max_bytes = Application.fetch_env!(:robine, :storage_max_object_bytes)

    if byte_size(content) > max_bytes do
      {:error, :object_too_large}
    else
      digest = sha256(content)
      target = object_path(digest)
      temporary = temporary_path()

      with :ok <- prepare_directories(target),
           :ok <- File.write(temporary, content, [:binary, :exclusive]),
           :ok <- publish(temporary, target) do
        {:ok, %{blob_id: digest, digest: digest, size: byte_size(content)}}
      else
        {:error, reason} ->
          _ = File.rm(temporary)
          {:error, {:blob_write, reason}}
      end
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

  defp prepare_directories(target) do
    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.mkdir_p(Path.join(root(), ".tmp")) do
      :ok
    end
  end

  defp publish(temporary, target) do
    case File.rename(temporary, target) do
      :ok -> :ok
      {:error, :eexist} -> File.rm(temporary)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_id(blob_id),
    do: if(Regex.match?(@blob_id, blob_id), do: :ok, else: {:error, :invalid_blob_id})

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp object_path(blob_id),
    do: Path.join([root(), "objects", binary_part(blob_id, 0, 2), blob_id])

  defp temporary_path, do: Path.join([root(), ".tmp", Ecto.UUID.generate()])
  defp root, do: Application.fetch_env!(:robine, :storage_root)
end
