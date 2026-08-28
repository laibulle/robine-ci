defmodule Mix.Tasks.Robine.GoRunnerReleaseSmoke do
  use Mix.Task

  @shortdoc "Cross-compiles and inspects every Go runner release target"

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

  @magic %{
    "darwin" => <<0xCF, 0xFA, 0xED, 0xFE>>,
    "linux" => <<0x7F, 0x45, 0x4C, 0x46>>,
    "windows" => <<0x4D, 0x5A>>
  }

  @impl true
  def run([]) do
    output = Path.join(System.tmp_dir!(), "robine-go-runner-#{Ecto.UUID.generate()}")

    try do
      Mix.Task.reenable("robine.go_runner_release")
      Mix.Task.run("robine.go_runner_release", ["--output", output])
      version = Mix.Project.config() |> Keyword.fetch!(:version)

      Enum.each(@targets, fn target -> verify_target!(output, version, target) end)
      Mix.shell().info("Go runner release smoke passed")
    after
      File.rm_rf!(output)
    end
  end

  def run(_arguments), do: Mix.raise("usage: mix robine.go_runner_release_smoke")

  defp verify_target!(output, version, target) do
    directory = Path.join(output, target.directory)
    manifest = Path.join(directory, "RUNNER_SHA256SUMS")
    :ok = Robine.Release.Checksums.verify(manifest, directory)

    Enum.each(target.architectures, fn architecture ->
      path =
        Path.join(
          directory,
          "robine-runner-#{version}-#{target.goos}-#{architecture}#{target.extension}"
        )

      assert_magic!(path, Map.fetch!(@magic, target.goos))
      assert_go_metadata!(path, target.goos, architecture)
      assert_embedded_version!(path, version)
    end)
  end

  defp assert_magic!(path, expected) do
    with {:ok, file} <- File.open(path, [:read, :binary]),
         {:ok, ^expected} <- :file.read(file, byte_size(expected)),
         :ok <- File.close(file) do
      :ok
    else
      _failure -> Mix.raise("#{Path.basename(path)} has an unexpected executable format")
    end
  end

  defp assert_go_metadata!(path, goos, architecture) do
    go = System.get_env("ROBINE_GO") || System.find_executable("go")
    {metadata, status} = System.cmd(go, ["version", "-m", path], stderr_to_stdout: true)

    unless status == 0 and metadata =~ "build\tCGO_ENABLED=0" and
             metadata =~ "build\tGOOS=#{goos}" and
             metadata =~ "build\tGOARCH=#{architecture}" do
      Mix.raise("#{Path.basename(path)} has unexpected Go build metadata: #{metadata}")
    end
  end

  defp assert_embedded_version!(path, version) do
    if :binary.match(File.read!(path), version) == :nomatch do
      Mix.raise("#{Path.basename(path)} does not embed version #{version}")
    end
  end
end
