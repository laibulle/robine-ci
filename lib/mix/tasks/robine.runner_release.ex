defmodule Mix.Tasks.Robine.RunnerRelease do
  use Mix.Task

  @shortdoc "Builds the standalone remote runner escript and checksum"

  @impl true
  def run(arguments) do
    {options, positional, invalid} =
      OptionParser.parse(arguments, strict: [output: :string], aliases: [o: :output])

    if invalid != [] or positional != [] do
      Mix.raise("usage: mix robine.runner_release [--output DIRECTORY]")
    end

    output = Path.expand(options[:output] || "dist/runner")
    version = Mix.Project.config() |> Keyword.fetch!(:version)
    artifact = Path.join(output, "robine-runner-#{version}.escript")
    manifest = Path.join(output, "RUNNER_SHA256SUMS")
    native_artifacts = native_artifacts(output)
    File.mkdir_p!(output)

    {build_output, build_status} =
      System.cmd("mix", ["escript.build"],
        cd: File.cwd!(),
        env: [
          {"MIX_ENV", "runner"},
          {"ROBINE_ESCRIPT_TARGET", "runner"},
          {"ROBINE_ESCRIPT_PATH", artifact}
        ],
        stderr_to_stdout: true
      )

    if build_status != 0 do
      Mix.raise("runner escript build failed: #{build_output}")
    end

    with :ok <- copy_native_artifacts(native_artifacts),
         {:ok, _path} <-
           Robine.Release.Checksums.write(
             [artifact | Enum.map(native_artifacts, &elem(&1, 1))],
             manifest
           ) do
      Mix.shell().info("Created #{artifact}")
      Mix.shell().info("Created #{manifest}")
    else
      {:error, reason} ->
        Mix.raise("runner release packaging failed: #{inspect(reason)}")
    end
  end

  defp native_artifacts(output) do
    root = Path.join([File.cwd!(), "_build", "runner", "lib", "exile"])

    [
      {Path.join(root, "ebin/exile.app"), Path.join(output, "robine-exile.app")},
      {Path.join(root, "priv/exile.so"), Path.join(output, "robine-exile.so")},
      {Path.join(root, "priv/spawner"), Path.join(output, "robine-exile-spawner")}
    ]
  end

  defp copy_native_artifacts(artifacts) do
    Enum.reduce_while(artifacts, :ok, fn {source, target}, :ok ->
      with true <- File.regular?(source),
           :ok <- File.cp(source, target),
           :ok <- maybe_executable(target) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, {:native_artifact_missing, Path.basename(source)}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_executable(path) do
    if String.ends_with?(path, "spawner"), do: File.chmod(path, 0o755), else: :ok
  end
end
