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

    runtime_root =
      Path.join(
        System.tmp_dir!(),
        "robine-cli-native-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    # OTP resolves an application's priv directory from an app-shaped code path.
    # Keeping ebin directly below the arbitrary runtime root makes
    # :code.priv_dir/1 return {:error, :bad_name}.
    runtime_directory = Path.join(runtime_root, "exile")
    ebin = Path.join(runtime_directory, "ebin")

    with :ok <- copy_bundle(bundle_directory, runtime_directory),
         :ok <- register_cleanup(runtime_root),
         :ok <- unload_embedded_application(),
         true <- :code.add_patha(String.to_charlist(ebin)),
         :ok <- load_external_application(),
         path when is_list(path) <- :code.priv_dir(:exile),
         true <- File.regular?(Path.join(to_string(path), "spawner")),
         :ok <- start_external_application() do
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

  defp load_external_application do
    case Application.load(:exile) do
      :ok -> :ok
      {:error, {:already_loaded, :exile}} -> :ok
      {:error, reason} -> {:error, {:native_application_load, reason}}
    end
  end

  defp start_external_application do
    case Application.ensure_all_started(:exile) do
      {:ok, _applications} -> :ok
      {:error, reason} -> {:error, {:native_application_start, reason}}
    end
  end

  defp register_cleanup(runtime_root) do
    System.at_exit(fn _status -> File.rm_rf(runtime_root) end)
    :ok
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
