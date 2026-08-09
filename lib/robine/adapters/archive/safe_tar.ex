defmodule Robine.Adapters.Archive.SafeTar do
  @moduledoc false

  @defaults [
    max_archive_bytes: 100_000_000,
    max_files: 10_000,
    max_expanded_bytes: 1_000_000_000,
    max_ratio: 100,
    timeout_ms: 10_000
  ]

  def extract_source(body, options \\ []) when is_binary(body) do
    options = Keyword.merge(@defaults, options)

    with :ok <- compressed_size(body, options),
         {:ok, table} <-
           timed(fn -> :erl_tar.table({:binary, body}, [:compressed, :verbose]) end, options),
         :ok <- validate_table(table, byte_size(body), options),
         {:ok, entries} <-
           timed(fn -> :erl_tar.extract({:binary, body}, [:compressed, :memory]) end, options),
         {:ok, files} <- normalize(entries, options) do
      {:ok, files}
    end
  end

  def validate_table(entries, compressed_bytes, options \\ []) when is_list(entries) do
    options = Keyword.merge(@defaults, options)

    Enum.reduce_while(entries, {:ok, 0, 0}, fn
      {path, :directory, _size, _mtime, _mode, _uid, _gid}, {:ok, files, total} ->
        case safe_relative_path(to_string(path)) do
          {:ok, _relative} -> {:cont, {:ok, files, total}}
          error -> {:halt, error}
        end

      {path, :regular, size, _mtime, _mode, _uid, _gid}, {:ok, files, total}
      when is_integer(size) and size >= 0 ->
        with {:ok, _relative} <- safe_relative_path(to_string(path)),
             true <- files + 1 <= options[:max_files],
             true <- total + size <= options[:max_expanded_bytes],
             true <- ratio_safe?(total + size, compressed_bytes, options[:max_ratio]) do
          {:cont, {:ok, files + 1, total + size}}
        else
          false -> {:halt, {:error, :source_archive_limits_exceeded}}
          error -> {:halt, error}
        end

      _entry, _accumulator ->
        {:halt, {:error, :unsupported_source_archive_entry}}
    end)
    |> case do
      {:ok, _files, _total} -> :ok
      error -> error
    end
  end

  def validate_workspace_archive(body, options \\ []) when is_binary(body) do
    options = Keyword.merge(@defaults, options)

    with :ok <- compressed_size(body, options),
         {:ok, table} <-
           timed(fn -> :erl_tar.table({:binary, body}, [:compressed, :verbose]) end, options) do
      validate_workspace_table(table, byte_size(body), options)
    end
  end

  @doc false
  def validate_workspace_table(entries, compressed_bytes, options \\ []) do
    options = Keyword.merge(@defaults, options)

    Enum.reduce_while(entries, {:ok, 0, 0}, fn
      {path, type, size, _mtime, _mode, _uid, _gid}, {:ok, files, total}
      when type in [:regular, :directory] and is_integer(size) and size >= 0 ->
        next_files = if type == :regular, do: files + 1, else: files
        next_total = if type == :regular, do: total + size, else: total

        if safe_workspace_path?(to_string(path)) and next_files <= options[:max_files] and
             next_total <= options[:max_expanded_bytes] and
             ratio_safe?(next_total, compressed_bytes, options[:max_ratio]) do
          {:cont, {:ok, next_files, next_total}}
        else
          {:halt, {:error, :unsafe_workspace_archive}}
        end

      _entry, _accumulator ->
        {:halt, {:error, :unsupported_source_archive_entry}}
    end)
    |> case do
      {:ok, _files, _total} -> :ok
      error -> error
    end
  end

  defp compressed_size(body, options) do
    if byte_size(body) <= options[:max_archive_bytes],
      do: :ok,
      else: {:error, :source_archive_too_large}
  end

  defp ratio_safe?(0, _compressed, _ratio), do: true
  defp ratio_safe?(_expanded, 0, _ratio), do: false
  defp ratio_safe?(expanded, compressed, ratio), do: expanded <= compressed * ratio

  defp normalize(entries, options) do
    Enum.reduce_while(entries, {:ok, [], 0}, fn
      {path, content}, {:ok, files, total} when is_binary(content) ->
        with {:ok, relative} <- safe_relative_path(to_string(path)),
             expanded = total + byte_size(content),
             true <- length(files) + 1 <= options[:max_files],
             true <- expanded <= options[:max_expanded_bytes] do
          {:cont, {:ok, [{relative, content} | files], expanded}}
        else
          false -> {:halt, {:error, :source_archive_limits_exceeded}}
          error -> {:halt, error}
        end

      _entry, _accumulator ->
        {:halt, {:error, :unsupported_source_archive_entry}}
    end)
    |> case do
      {:ok, files, _total} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp safe_relative_path(path) do
    case Path.split(path) do
      [_archive_root | relative] when relative != [] ->
        candidate = Path.join(relative)

        if Path.type(candidate) == :relative and ".." not in relative and
             byte_size(candidate) <= 4_096 and not String.contains?(candidate, <<0>>),
           do: {:ok, candidate},
           else: {:error, :unsafe_source_archive_path}

      _ ->
        {:error, :unsafe_source_archive_path}
    end
  end

  defp safe_workspace_path?(path) do
    path != "." and Path.type(path) == :relative and ".." not in Path.split(path) and
      byte_size(path) <= 4_096 and not String.contains?(path, <<0>>)
  end

  defp timed(function, options) do
    task = Task.async(function)

    case Task.yield(task, options[:timeout_ms]) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :invalid_source_archive}
      nil -> {:error, :source_archive_timeout}
    end
  end
end
