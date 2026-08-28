defmodule Mix.Tasks.Robine.MacosRunnerRelease do
  use Mix.Task

  @shortdoc "Cross-compiles the self-contained Go runner for macOS"

  @impl true
  def run(arguments) do
    {options, positional, invalid} =
      OptionParser.parse(arguments, strict: [output: :string], aliases: [o: :output])

    if invalid != [] or positional != [] do
      Mix.raise("usage: mix robine.macos_runner_release [--output DIRECTORY]")
    end

    go = System.get_env("ROBINE_GO") || System.find_executable("go")

    unless is_binary(go) do
      Mix.raise("Go is required; install the pinned toolchain or set ROBINE_GO")
    end

    output = Path.expand(options[:output] || "dist/runner-macos")
    version = Mix.Project.config() |> Keyword.fetch!(:version)
    root = Path.join(File.cwd!(), "runner-go")
    File.mkdir_p!(output)

    artifacts =
      for architecture <- ~w(arm64 amd64) do
        artifact = Path.join(output, "robine-runner-#{version}-darwin-#{architecture}")

        {build_output, status} =
          System.cmd(
            go,
            [
              "build",
              "-mod=readonly",
              "-trimpath",
              "-ldflags",
              "-s -w -X main.version=#{version}",
              "-o",
              artifact,
              "./cmd/robine-runner"
            ],
            cd: root,
            env: [{"CGO_ENABLED", "0"}, {"GOOS", "darwin"}, {"GOARCH", architecture}],
            stderr_to_stdout: true
          )

        if status != 0 do
          Mix.raise("macOS Go runner build failed for #{architecture}: #{build_output}")
        end

        File.chmod!(artifact, 0o755)
        Mix.shell().info("Created #{artifact}")
        artifact
      end

    manifest = Path.join(output, "RUNNER_SHA256SUMS")

    case Robine.Release.Checksums.write(artifacts, manifest) do
      {:ok, _path} -> Mix.shell().info("Created #{manifest}")
      {:error, reason} -> Mix.raise("runner checksum creation failed: #{inspect(reason)}")
    end
  end
end
