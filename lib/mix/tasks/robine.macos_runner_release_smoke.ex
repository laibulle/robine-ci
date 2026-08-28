defmodule Mix.Tasks.Robine.MacosRunnerReleaseSmoke do
  use Mix.Task

  @shortdoc "Cross-compiles and inspects both macOS Go runner binaries"

  @mach_o_64 <<0xCF, 0xFA, 0xED, 0xFE>>

  @impl true
  def run([]) do
    output = Path.join(System.tmp_dir!(), "robine-macos-runner-#{Ecto.UUID.generate()}")

    try do
      Mix.Task.reenable("robine.macos_runner_release")
      Mix.Task.run("robine.macos_runner_release", ["--output", output])
      version = Mix.Project.config() |> Keyword.fetch!(:version)
      manifest = Path.join(output, "RUNNER_SHA256SUMS")

      :ok = Robine.Release.Checksums.verify(manifest, output)

      for architecture <- ~w(arm64 amd64) do
        path = Path.join(output, "robine-runner-#{version}-darwin-#{architecture}")
        assert_mach_o!(path)
      end

      Mix.shell().info("macOS Go runner release smoke passed")
    after
      File.rm_rf!(output)
    end
  end

  def run(_arguments), do: Mix.raise("usage: mix robine.macos_runner_release_smoke")

  defp assert_mach_o!(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]),
         {:ok, @mach_o_64} <- :file.read(file, 4),
         :ok <- File.close(file) do
      :ok
    else
      _failure -> Mix.raise("#{Path.basename(path)} is not a 64-bit Mach-O executable")
    end
  end
end
