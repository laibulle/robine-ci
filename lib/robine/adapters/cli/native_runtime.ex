defmodule Robine.Adapters.CLI.NativeRuntime do
  @moduledoc false

  @bundle_files %{
    "robine-exile.app" => {"ebin", "exile.app"},
    "robine-exile.so" => {"priv", "exile.so"},
    "robine-exile-spawner" => {"priv", "spawner"}
  }

  @spec prepare() :: :ok | {:error, term()}
  def prepare do
    case :code.priv_dir(:exile) do
      path when is_list(path) ->
        if File.regular?(Path.join(to_string(path), "spawner")),
          do: :ok,
          else: prepare_bundle()

      {:error, _reason} ->
        prepare_bundle()
    end
  rescue
    error -> {:error, {:native_runtime, Exception.message(error)}}
  end

  defp prepare_bundle do
    bundle_directory = :escript.script_name() |> to_string() |> Path.expand() |> Path.dirname()

    runtime_directory =
      Path.join(
        System.tmp_dir!(),
        "robine-cli-native-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    ebin = Path.join(runtime_directory, "ebin")

    with :ok <- copy_bundle(bundle_directory, runtime_directory),
         :ok <- unload_embedded_application(),
         :ok <- remove_embedded_code_paths(),
         true <- :code.add_patha(String.to_charlist(ebin)),
         :ok <- load_external_application(),
         path when is_list(path) <- :code.priv_dir(:exile),
         true <- File.regular?(Path.join(to_string(path), "spawner")) do
      :ok
    else
      false -> {:error, :native_code_path_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unload_embedded_application do
    case Application.unload(:exile) do
      :ok -> :ok
      {:error, {:not_loaded, :exile}} -> :ok
      {:error, reason} -> {:error, {:native_application_unload, reason}}
    end
  end

  defp remove_embedded_code_paths do
    :code.get_path()
    |> Enum.filter(fn path ->
      path = to_string(path)
      String.contains?(path, ".escript/") and String.ends_with?(path, "/exile/ebin")
    end)
    |> Enum.each(&:code.del_path/1)

    :ok
  end

  defp load_external_application do
    case Application.load(:exile) do
      :ok -> :ok
      {:error, {:already_loaded, :exile}} -> :ok
      {:error, reason} -> {:error, {:native_application_load, reason}}
    end
  end

  defp copy_bundle(bundle_directory, runtime_directory) do
    Enum.reduce_while(@bundle_files, :ok, fn {source_name, {directory, target_name}}, :ok ->
      source = Path.join(bundle_directory, source_name)
      target_directory = Path.join(runtime_directory, directory)
      target = Path.join(target_directory, target_name)

      with true <- File.regular?(source),
           :ok <- File.mkdir_p(target_directory),
           :ok <- File.cp(source, target),
           :ok <- maybe_make_executable(target_name, target) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, {:missing_native_bundle_file, source_name}}}
        {:error, reason} -> {:halt, {:error, {:native_bundle_copy, source_name, reason}}}
      end
    end)
  end

  defp maybe_make_executable("spawner", path), do: File.chmod(path, 0o755)
  defp maybe_make_executable(_name, _path), do: :ok
end
