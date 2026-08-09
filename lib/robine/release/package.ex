defmodule Robine.Release.Package do
  @moduledoc "Packages one versioned CLI executable with its checksum manifest."

  alias Robine.Release.Checksums

  @spec create(Path.t(), Path.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def create(source, output_directory, version)
      when is_binary(source) and is_binary(output_directory) and is_binary(version) do
    artifact_name = "robine-#{version}.escript"
    artifact = Path.join(output_directory, artifact_name)
    manifest = Path.join(output_directory, "SHA256SUMS")

    with true <-
           Regex.match?(
             ~r/\A[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?\z/,
             version
           ),
         true <- File.regular?(source),
         :ok <- File.mkdir_p(output_directory),
         :ok <- copy_executable(source, artifact),
         {:ok, ^manifest} <- Checksums.write([artifact], manifest) do
      {:ok, %{artifact: artifact, manifest: manifest}}
    else
      false -> {:error, :invalid_release_input}
      {:error, reason} -> {:error, reason}
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
