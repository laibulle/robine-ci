defmodule Robine.TestSupport.FakeS3Client do
  @moduledoc false
  @behaviour Robine.Adapters.Storage.S3Client

  def put_file(path, key, digest, size, config) do
    owner = Keyword.fetch!(config, :fake_owner)
    send(owner, {:s3_put, path, key, digest, size})

    case Keyword.get(config, :put_error) do
      nil ->
        unless Keyword.get(config, :record_only, false) do
          content = File.read!(path)
          Agent.update(Keyword.fetch!(config, :fake_store), &Map.put(&1, key, content))
        end

        :ok

      reason ->
        {:error, reason}
    end
  end

  def get(key, config) do
    case Keyword.get(config, :get_error) do
      nil ->
        case Agent.get(Keyword.fetch!(config, :fake_store), &Map.fetch(&1, key)) do
          {:ok, content} -> {:ok, content}
          :error -> {:error, :not_found}
        end

      reason ->
        {:error, reason}
    end
  end

  def delete(key, config) do
    Agent.update(Keyword.fetch!(config, :fake_store), &Map.delete(&1, key))
    :ok
  end

  def inventory(prefix, config) do
    case Keyword.get(config, :inventory_error) do
      nil ->
        objects =
          Keyword.fetch!(config, :fake_store)
          |> Agent.get(& &1)
          |> Enum.flat_map(fn {key, content} ->
            if String.starts_with?(key, prefix),
              do: [%{key: key, size: byte_size(content)}],
              else: []
          end)

        {:ok, objects}

      reason ->
        {:error, reason}
    end
  end

  def health(config), do: Keyword.get(config, :health_result, :ok)
end
