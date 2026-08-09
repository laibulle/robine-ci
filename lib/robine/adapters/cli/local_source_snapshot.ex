defmodule Robine.Adapters.CLI.LocalSourceSnapshot do
  @moduledoc false

  @spec create(Path.t()) :: {:ok, %{path: Path.t(), source_root: Path.t()}} | {:error, term()}
  def create(source_path) when is_binary(source_path) do
    with {:ok, source_root, files} <- source_files(source_path),
         {:ok, snapshot} <- snapshot_directory(),
         :ok <- copy_source(source_root, snapshot, files) do
      {:ok, %{path: snapshot, source_root: source_root}}
    end
  end

  def create(_source_path), do: {:error, :invalid_local_source_path}

  @spec cleanup(map()) :: :ok
  def cleanup(%{path: path}) when is_binary(path) do
    _ = File.rm_rf(path)
    :ok
  end

  defp source_files(source_path) do
    source_path = Path.expand(source_path)

    case git_root(source_path) do
      {:ok, root} -> git_files(root)
      :not_a_repository -> {:ok, source_path, :recursive}
      {:error, _reason} = error -> error
    end
  end

  defp git_root(source_path) do
    case System.find_executable("git") do
      nil ->
        :not_a_repository

      git ->
        case System.cmd(git, ["-C", source_path, "rev-parse", "--show-toplevel"],
               stderr_to_stdout: true
             ) do
          {root, 0} -> {:ok, root |> String.trim_trailing() |> Path.expand()}
          {_output, _status} -> :not_a_repository
        end
    end
  rescue
    _error -> {:error, :git_source_discovery_failed}
  end

  defp git_files(root) do
    git = System.find_executable("git")

    case System.cmd(
           git,
           [
             "-C",
             root,
             "ls-files",
             "--cached",
             "--others",
             "--exclude-standard",
             "--full-name",
             "-z"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, root, String.split(output, <<0>>, trim: true)}
      {_output, _status} -> {:error, :git_source_listing_failed}
    end
  rescue
    _error -> {:error, :git_source_listing_failed}
  end

  defp snapshot_directory do
    path =
      Path.join(
        System.tmp_dir!(),
        "robine-local-source-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    case File.mkdir(path) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:local_source_snapshot, reason}}
    end
  end

  defp copy_source(source_root, snapshot, :recursive) do
    case copy_tree(source_root, snapshot, true) do
      :ok -> :ok
      {:error, reason} -> cleanup_error(snapshot, reason)
    end
  end

  defp copy_source(source_root, snapshot, files) when is_list(files) do
    files
    |> Enum.reduce_while(:ok, fn relative, :ok ->
      with :ok <- safe_relative_path(relative),
           :ok <- copy_regular(Path.join(source_root, relative), Path.join(snapshot, relative)) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, reason} -> cleanup_error(snapshot, reason)
    end
  end

  defp copy_tree(source, target, root?) do
    with {:ok, entries} <- File.ls(source),
         :ok <- File.mkdir_p(target) do
      entries
      |> Enum.reject(&(root? and &1 == ".git"))
      |> Enum.reduce_while(:ok, fn entry, :ok ->
        child_source = Path.join(source, entry)
        child_target = Path.join(target, entry)

        result =
          case File.lstat(child_source) do
            {:ok, %File.Stat{type: :directory}} -> copy_tree(child_source, child_target, false)
            {:ok, %File.Stat{type: :regular}} -> copy_regular(child_source, child_target)
            {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_local_source_entry, entry, type}}
            {:error, reason} -> {:error, {:local_source_entry, entry, reason}}
          end

        case result do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp copy_regular(source, target) do
    case File.lstat(source) do
      {:ok, %File.Stat{type: :regular}} ->
        with :ok <- File.mkdir_p(Path.dirname(target)),
             :ok <- File.cp(source, target) do
          :ok
        else
          {:error, reason} -> {:error, {:local_source_copy, Path.basename(source), reason}}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsafe_local_source_entry, Path.basename(source), type}}

      {:error, reason} ->
        {:error, {:local_source_entry, Path.basename(source), reason}}
    end
  end

  defp safe_relative_path(path) when is_binary(path) and path != "" do
    components = Path.split(path)

    if Path.type(path) == :relative and ".." not in components,
      do: :ok,
      else: {:error, {:unsafe_local_source_path, path}}
  end

  defp safe_relative_path(path), do: {:error, {:unsafe_local_source_path, path}}

  defp cleanup_error(snapshot, reason) do
    _ = File.rm_rf(snapshot)
    {:error, reason}
  end
end
