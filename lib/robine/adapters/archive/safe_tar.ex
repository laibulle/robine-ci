defmodule Robine.Adapters.Archive.SafeTar do
  @moduledoc false
  @behaviour Robine.Transfers.Ports.Archive

  @max_archive_bytes 250_000_000

  @defaults [
    max_archive_bytes: @max_archive_bytes,
    max_files: 10_000,
    max_expanded_bytes: 1_000_000_000,
    max_ratio: 100,
    timeout_ms: 10_000
  ]

  @doc false
  @spec max_archive_bytes() :: pos_integer()
  def max_archive_bytes, do: @max_archive_bytes

  @impl true
  def create_source(files, options \\ []) when is_map(files) do
    options = Keyword.merge(@defaults, options)
    temporary = Path.join(System.tmp_dir!(), "robine-source-#{Ecto.UUID.generate()}.tar.gz")

    entries =
      Enum.map(files, fn {path, content} ->
        {String.to_charlist("source/" <> path), content}
      end)

    try do
      with true <- map_size(files) <= options[:max_files],
           true <- Enum.all?(files, fn {path, content} -> safe_input_file?(path, content) end),
           true <-
             Enum.reduce(files, 0, fn {_path, content}, total -> total + byte_size(content) end) <=
               options[:max_expanded_bytes],
           :ok <- :erl_tar.create(String.to_charlist(temporary), entries, [:compressed]),
           {:ok, body} <- File.read(temporary),
           :ok <- compressed_size(body, options) do
        {:ok, body}
      else
        false -> {:error, :source_archive_limits_exceeded}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:source_archive_create, other}}
      end
    after
      File.rm(temporary)
    end
  end

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

    Enum.reduce_while(entries, {:ok, 0, 0, 0}, fn
      {path, :directory, _size, _mtime, _mode, _uid, _gid},
      {:ok, archive_entries, files, total} ->
        with :ok <- safe_archive_directory_path(to_string(path)),
             true <- archive_entries + 1 <= options[:max_files] do
          {:cont, {:ok, archive_entries + 1, files, total}}
        else
          false -> {:halt, {:error, :source_archive_limits_exceeded}}
          error -> {:halt, error}
        end

      {~c"pax_global_header", :unknown, size, _mtime, _mode, _uid, _gid},
      {:ok, archive_entries, files, total}
      when is_integer(size) and size >= 0 and size <= 65_536 ->
        if archive_entries + 1 <= options[:max_files],
          do: {:cont, {:ok, archive_entries + 1, files, total}},
          else: {:halt, {:error, :source_archive_limits_exceeded}}

      {path, :regular, size, _mtime, _mode, _uid, _gid}, {:ok, archive_entries, files, total}
      when is_integer(size) and size >= 0 ->
        with {:ok, _relative} <- safe_relative_path(to_string(path)),
             true <- archive_entries + 1 <= options[:max_files],
             true <- files + 1 <= options[:max_files],
             true <- total + size <= options[:max_expanded_bytes],
             true <- ratio_safe?(total + size, compressed_bytes, options[:max_ratio]) do
          {:cont, {:ok, archive_entries + 1, files + 1, total + size}}
        else
          false -> {:halt, {:error, :source_archive_limits_exceeded}}
          error -> {:halt, error}
        end

      _entry, _accumulator ->
        {:halt, {:error, :unsupported_source_archive_entry}}
    end)
    |> case do
      {:ok, _archive_entries, _files, _total} -> :ok
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
      {~c"pax_global_header", content}, {:ok, files, total}
      when is_binary(content) and byte_size(content) <= 65_536 ->
        {:cont, {:ok, files, total}}

      {"pax_global_header", content}, {:ok, files, total}
      when is_binary(content) and byte_size(content) <= 65_536 ->
        {:cont, {:ok, files, total}}

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

  defp safe_archive_directory_path(path) do
    case Path.split(path) do
      [archive_root]
      when archive_root not in ["", ".", ".."] and byte_size(archive_root) <= 4_096 ->
        if Path.type(path) == :relative and not String.contains?(path, <<0>>),
          do: :ok,
          else: {:error, :unsafe_source_archive_path}

      [_archive_root | _relative] ->
        case safe_relative_path(path) do
          {:ok, _relative} -> :ok
          error -> error
        end

      _invalid ->
        {:error, :unsafe_source_archive_path}
    end
  end

  defp safe_input_file?(path, content) when is_binary(path) and is_binary(content) do
    parts = Path.split(path)

    path != "" and Path.type(path) == :relative and ".." not in parts and
      byte_size(path) <= 4_089 and not String.contains?(path, <<0>>)
  end

  defp safe_input_file?(_path, _content), do: false

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
