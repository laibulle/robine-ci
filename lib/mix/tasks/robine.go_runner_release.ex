defmodule Mix.Tasks.Robine.GoRunnerRelease do
  use Mix.Task

  @shortdoc "Cross-compiles the self-contained Go runner release targets"

  @targets [
    %{directory: "macos", goos: "darwin", architectures: ~w(arm64 amd64), extension: ""},
    %{directory: "linux", goos: "linux", architectures: ~w(arm64 amd64), extension: ""},
    %{
      directory: "windows",
      goos: "windows",
      architectures: ~w(arm64 amd64),
      extension: ".exe"
    }
  ]

  @impl true
  def run(arguments) do
    {options, positional, invalid} =
      OptionParser.parse(arguments, strict: [output: :string], aliases: [o: :output])

    if invalid != [] or positional != [] do
      Mix.raise("usage: mix robine.go_runner_release [--output DIRECTORY]")
    end

    go = System.get_env("ROBINE_GO") || System.find_executable("go")

    unless is_binary(go) do
      Mix.raise("Go is required; install the pinned toolchain or set ROBINE_GO")
    end

    output = Path.expand(options[:output] || "dist/runner-go")

    if File.exists?(output) do
      Mix.raise("runner release output already exists: #{output}")
    end

    version = Mix.Project.config() |> Keyword.fetch!(:version)
    root = Path.join(File.cwd!(), "runner-go")

    Enum.each(@targets, fn target -> build_target!(go, root, output, version, target) end)
  end

  defp build_target!(go, root, output, version, target) do
    target_output = Path.join(output, target.directory)
    File.mkdir_p!(target_output)

    artifacts =
      Enum.map(target.architectures, fn architecture ->
        artifact =
          Path.join(
            target_output,
            "robine-runner-#{version}-#{target.goos}-#{architecture}#{target.extension}"
          )

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
            env: [
              {"CGO_ENABLED", "0"},
              {"GOOS", target.goos},
              {"GOARCH", architecture}
            ],
            stderr_to_stdout: true
          )

        if status != 0 do
          Mix.raise("Go runner build failed for #{target.goos}/#{architecture}: #{build_output}")
        end

        if target.goos != "windows", do: File.chmod!(artifact, 0o755)
        Mix.shell().info("Created #{artifact}")
        artifact
      end)

    manifest = Path.join(target_output, "RUNNER_SHA256SUMS")

    case Robine.Release.Checksums.write(artifacts, manifest) do
      {:ok, _path} -> Mix.shell().info("Created #{manifest}")
      {:error, reason} -> Mix.raise("runner checksum creation failed: #{inspect(reason)}")
    end
  end
end
