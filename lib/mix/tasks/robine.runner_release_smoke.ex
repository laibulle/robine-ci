defmodule Mix.Tasks.Robine.RunnerReleaseSmoke do
  use Mix.Task

  @shortdoc "Builds and executes the standalone runner artifact"

  @impl true
  def run([]) do
    output = Path.join(System.tmp_dir!(), "robine-runner-release-#{Ecto.UUID.generate()}")

    try do
      Mix.Task.reenable("robine.runner_release")
      Mix.Task.run("robine.runner_release", ["--output", output])

      version = Mix.Project.config() |> Keyword.fetch!(:version)
      artifact = Path.join(output, "robine-runner-#{version}.escript")
      manifest = Path.join(output, "RUNNER_SHA256SUMS")

      :ok = Robine.Release.Checksums.verify(manifest, output)

      case System.cmd(artifact, ["version"], stderr_to_stdout: true) do
        {"robine-runner " <> returned, 0} ->
          if String.trim(returned) == version do
            Mix.shell().info("Runner release smoke passed")
          else
            Mix.raise("runner release returned unexpected version #{inspect(returned)}")
          end

        {output, status} ->
          Mix.raise("runner release failed with #{status}: #{output}")
      end
    after
      File.rm_rf!(output)
    end
  end

  def run(_arguments), do: Mix.raise("usage: mix robine.runner_release_smoke")
end
