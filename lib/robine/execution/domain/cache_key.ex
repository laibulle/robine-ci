defmodule Robine.Execution.Domain.CacheKey do
  @moduledoc "Pure, restricted cache-key checksum expansion."

  @expression ~r/\$\{\{\s*checksum\('([^']+)'\)\s*\}\}/

  @spec resolve(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve(template, workspace_root) when is_binary(template) and is_binary(workspace_root) do
    Regex.scan(@expression, template)
    |> Enum.reduce_while({:ok, template}, fn [expression, relative], {:ok, key} ->
      with {:ok, path} <- safe_file(workspace_root, relative),
           {:ok, content} <- File.read(path) do
        digest = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
        {:cont, {:ok, String.replace(key, expression, digest)}}
      else
        {:error, reason} -> {:halt, {:error, {:cache_checksum, relative, reason}}}
      end
    end)
  end

  defp safe_file(root, relative) do
    expanded_root = Path.expand(root)
    candidate = Path.expand(relative, expanded_root)

    if candidate != expanded_root and String.starts_with?(candidate, expanded_root <> "/") do
      case File.lstat(candidate) do
        {:ok, %File.Stat{type: :regular}} -> {:ok, candidate}
        {:ok, %File.Stat{type: type}} -> {:error, {:unsupported_type, type}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :unsafe_path}
    end
  end
end
