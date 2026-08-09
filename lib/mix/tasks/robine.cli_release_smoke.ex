defmodule Mix.Tasks.Robine.CliReleaseSmoke do
  use Mix.Task

  @shortdoc "Builds and executes the real CLI release bundle"

  @workflow """
  version: 1
  name: Release smoke
  on:
    push: {}
  jobs:
    test:
      image: alpine:3.22
      steps:
        - name: Intentional failure
          run: "printf 'release smoke failure\\n' >&2; exit 7"
  """

  @impl Mix.Task
  def run([]) do
    root = Path.join(System.tmp_dir!(), "robine-cli-release-smoke-#{unique_id()}")
    output = Path.join(root, "bundle")
    repository = Path.join(root, "repository")
    workflow = Path.join(repository, ".robine-ci/workflows/ci.yml")

    try do
      File.mkdir_p!(Path.dirname(workflow))
      File.write!(workflow, @workflow)
      build_bundle!(output)
      verify_bundle!(output)
      smoke_version!(output)
      smoke_failure!(output, repository, workflow)
      Mix.shell().info("CLI release smoke passed")
    after
      File.rm_rf!(root)
    end
  end

  def run(_arguments), do: Mix.raise("usage: mix robine.cli_release_smoke")

  defp build_bundle!(output) do
    {log, status} =
      System.cmd("mix", ["robine.release", "--output", output],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "cli"}],
        stderr_to_stdout: true
      )

    require_status!(status, 0, "CLI release build", log)
  end

  defp verify_bundle!(output) do
    manifest = Path.join(output, "SHA256SUMS")

    case Robine.Release.Checksums.verify(manifest, output) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("CLI release checksum verification failed: #{inspect(reason)}")
    end
  end

  defp smoke_version!(output) do
    executable = executable(output)
    {log, status} = System.cmd(executable, ["version"], stderr_to_stdout: true)
    require_status!(status, 0, "CLI version smoke", log)

    unless log =~ "robine #{Mix.Project.config()[:version]}" do
      Mix.raise("CLI version smoke returned unexpected output:\n#{log}")
    end
  end

  defp smoke_failure!(output, repository, workflow) do
    executable = executable(output)

    {log, status} =
      System.cmd(executable, ["run", "test", "--workflow", workflow],
        cd: repository,
        stderr_to_stdout: true
      )

    require_status!(status, 5, "CLI failed-job smoke", log)

    unless log =~ "release smoke failure" and log =~ "Job failed: command_failed" do
      Mix.raise("CLI failed-job smoke returned unexpected output:\n#{log}")
    end
  end

  defp executable(output) do
    Path.join(output, "robine-#{Mix.Project.config()[:version]}.escript")
  end

  defp require_status!(actual, expected, label, log) do
    if actual != expected do
      Mix.raise("#{label} exited with #{actual}, expected #{expected}:\n#{log}")
    end
  end

  defp unique_id do
    "#{System.pid()}-#{System.unique_integer([:positive])}"
  end
end
