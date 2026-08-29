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
  def create_source(files, options \\ [])

  def create_source(files, options) when is_map(files) do
    entries =
      Enum.map(files, fn {path, content} -> %{path: path, content: content, mode: 0o644} end)

    create_source(entries, options)
  end

  def create_source(files, options) when is_list(files) do
    options = Keyword.merge(@defaults, options)
    temporary = Path.join(System.tmp_dir!(), "robine-source-#{Ecto.UUID.generate()}.tar.gz")

    try do
      with {:ok, entries} <- normalize_source_files(files),
           true <- length(entries) <= options[:max_files],
           true <-
             Enum.reduce(entries, 0, fn entry, total -> total + byte_size(entry.content) end) <=
               options[:max_expanded_bytes],
           :ok <- write_source_archive(temporary, entries),
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
         {:ok, files} <- normalize(entries, table, options) do
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

  defp normalize(entries, table, options) do
    modes =
      Map.new(table, fn
        {path, :regular, _size, _mtime, mode, _uid, _gid} ->
          {to_string(path), source_mode(mode)}

        {path, _type, _size, _mtime, _mode, _uid, _gid} ->
          {to_string(path), 0o644}
      end)

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
          file = %{path: relative, content: content, mode: Map.get(modes, to_string(path), 0o644)}
          {:cont, {:ok, [file | files], expanded}}
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

  defp normalize_source_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, entries} ->
      case normalize_source_file(file) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        :error -> {:halt, {:error, :invalid_source_file}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp normalize_source_file(%{path: path, content: content, mode: mode})
       when is_integer(mode) do
    if safe_input_file?(path, content),
      do: {:ok, %{path: path, content: content, mode: source_mode(mode)}},
      else: :error
  end

  defp normalize_source_file({path, content, mode}) when is_integer(mode),
    do: normalize_source_file(%{path: path, content: content, mode: mode})

  defp normalize_source_file({path, content}),
    do: normalize_source_file(%{path: path, content: content, mode: 0o644})

  defp normalize_source_file(_file), do: :error

  defp safe_input_file?(path, content) when is_binary(path) and is_binary(content) do
    parts = Path.split(path)

    path != "" and Path.type(path) == :relative and ".." not in parts and
      byte_size(path) <= 4_089 and not String.contains?(path, <<0>>)
  end

  defp safe_input_file?(_path, _content), do: false

  defp source_mode(mode) when is_integer(mode) and mode >= 0 do
    if Bitwise.band(mode, 0o111) == 0, do: 0o644, else: 0o755
  end

  defp source_mode(_mode), do: 0o644

  defp write_source_archive(path, entries) do
    case :erl_tar.open(String.to_charlist(path), [:write, :compressed]) do
      {:ok, archive} ->
        result =
          Enum.reduce_while(entries, :ok, fn entry, :ok ->
            options = [{:mode, entry.mode}, {:mtime, 0}, {:uid, 0}, {:gid, 0}]

            case :erl_tar.add(
                   archive,
                   entry.content,
                   String.to_charlist("source/" <> entry.path),
                   options
                 ) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        close_result = :erl_tar.close(archive)

        case {result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close} -> {:error, reason}
          {:ok, {:error, reason}} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
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
