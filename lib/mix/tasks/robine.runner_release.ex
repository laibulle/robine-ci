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
    File.mkdir_p!(output)

    {build_output, build_status} =
      System.cmd("mix", ["escript.build"],
        cd: File.cwd!(),
        env: [
          {"MIX_ENV", Atom.to_string(Mix.env())},
          {"ROBINE_ESCRIPT_TARGET", "runner"},
          {"ROBINE_ESCRIPT_PATH", artifact}
        ],
        stderr_to_stdout: true
      )

    if build_status != 0 do
      Mix.raise("runner escript build failed: #{build_output}")
    end

    case Robine.Release.Checksums.write([artifact], manifest) do
      {:ok, _path} ->
        Mix.shell().info("Created #{artifact}")
        Mix.shell().info("Created #{manifest}")

      {:error, reason} ->
        Mix.raise("runner release packaging failed: #{inspect(reason)}")
    end
  end
end
