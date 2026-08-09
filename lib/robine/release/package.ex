defmodule Robine.Release.Package do
  @moduledoc "Packages one versioned CLI executable with its checksum manifest."

  alias Robine.Release.Checksums

  @spec create(Path.t(), Path.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def create(source, output_directory, version)
      when is_binary(source) and is_binary(output_directory) and is_binary(version) do
    artifact_name = "robine-#{version}.escript"
    artifact = Path.join(output_directory, artifact_name)
    manifest = Path.join(output_directory, "SHA256SUMS")
    native_artifacts = native_artifacts(output_directory)

    with true <-
           Regex.match?(
             ~r/\A[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?\z/,
             version
           ),
         true <- File.regular?(source),
         :ok <- File.mkdir_p(output_directory),
         :ok <- copy_executable(source, artifact),
         :ok <- copy_native_artifacts(native_artifacts),
         {:ok, ^manifest} <-
           Checksums.write([artifact | Enum.map(native_artifacts, &elem(&1, 1))], manifest) do
      {:ok,
       %{
         artifact: artifact,
         native_artifacts: Enum.map(native_artifacts, &elem(&1, 1)),
         manifest: manifest
       }}
    else
      false -> {:error, :invalid_release_input}
      {:error, reason} -> {:error, reason}
    end
  end

  defp native_artifacts(output_directory) do
    [
      {Application.app_dir(:exile, "ebin/exile.app"),
       Path.join(output_directory, "robine-exile.app")},
      {Application.app_dir(:exile, "priv/exile.so"),
       Path.join(output_directory, "robine-exile.so")},
      {Application.app_dir(:exile, "priv/spawner"),
       Path.join(output_directory, "robine-exile-spawner")}
    ]
  end

  defp copy_native_artifacts(artifacts) do
    Enum.reduce_while(artifacts, :ok, fn {source, target}, :ok ->
      case copy_native(source, target) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp copy_native(source, target) do
    with true <- File.regular?(source),
         :ok <- File.cp(source, target),
         :ok <- if(String.ends_with?(target, "spawner"), do: File.chmod(target, 0o755), else: :ok) do
      :ok
    else
      false -> {:error, {:native_artifact_missing, Path.basename(source)}}
      {:error, reason} -> {:error, {:native_artifact_write, Path.basename(target), reason}}
    end
  end

  defp copy_executable(source, artifact) do
    temporary = artifact <> ".#{Ecto.UUID.generate()}.tmp"

    with :ok <- File.cp(source, temporary),
         :ok <- File.chmod(temporary, 0o755),
         :ok <- File.rename(temporary, artifact) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, {:artifact_write, reason}}
    end
  end
end
