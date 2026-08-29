defmodule Mix.Tasks.Robine.ServerRelease do
  use Mix.Task

  @shortdoc "Builds a checksummed Robine server release archive"

  @impl Mix.Task
  def run(arguments) do
    {options, rest, invalid} =
      OptionParser.parse(arguments, strict: [output: :string], aliases: [o: :output])

    if rest != [] or invalid != [] do
      Mix.raise("usage: mix robine.server_release [--output DIRECTORY]")
    end

    output = Path.expand(Keyword.get(options, :output, "dist/server"))
    version = Mix.Project.config() |> Keyword.fetch!(:version)
    system_architecture = :erlang.system_info(:system_architecture) |> to_string()
    architecture = sanitize(system_architecture)
    platform = release_platform!()
    target = "#{platform.id}-#{platform.version}-#{architecture}"
    artifact_name = "robine-server-#{version}-#{target}.tar.gz"
    artifact = Path.join(output, artifact_name)
    temporary = artifact <> ".tmp-#{System.unique_integer([:positive])}"

    Mix.Task.run("assets.deploy")
    Mix.Task.run("release", ["--overwrite"])

    release_root = Path.join([Mix.Project.build_path(), "rel", "robine"])
    build_bundled_runner!(release_root, version, go_architecture!(system_architecture))

    try do
      with false <- File.exists?(artifact),
           :ok <- File.mkdir_p(output),
           :ok <- write_release_platform(release_root, platform, architecture),
           :ok <- File.cp("LICENSE", Path.join(release_root, "LICENSE")),
           :ok <-
             File.cp(
               "THIRD_PARTY_NOTICES.md",
               Path.join(release_root, "THIRD_PARTY_NOTICES.md")
             ),
           {_, 0} <-
             System.cmd("tar", ["-C", Path.dirname(release_root), "-czf", temporary, "robine"],
               stderr_to_stdout: true
             ),
           :ok <- File.rename(temporary, artifact),
           {:ok, manifest} <-
             Robine.Release.Checksums.write([artifact], Path.join(output, "SHA256SUMS")) do
        Mix.shell().info("Created #{artifact}")
        Mix.shell().info("Created #{manifest}")
      else
        true ->
          Mix.raise("release artifact already exists: #{artifact}")

        {command_output, status} when is_binary(command_output) and is_integer(status) ->
          Mix.raise("tar failed with status #{status}: #{command_output}")

        {:error, reason} ->
          Mix.raise("server release packaging failed: #{inspect(reason)}")
      end
    after
      if File.exists?(temporary), do: File.rm(temporary)
    end
  end

  defp sanitize(value), do: String.replace(value, ~r/[^A-Za-z0-9._-]/, "-")

  defp build_bundled_runner!(release_root, version, architecture) do
    go = System.get_env("ROBINE_GO") || System.find_executable("go")

    unless is_binary(go) do
      Mix.raise("Go is required to package the bundled server runner; set ROBINE_GO")
    end

    destination = Path.join([release_root, "bin", "rbe"])

    {output, status} =
      System.cmd(
        go,
        [
          "build",
          "-buildvcs=false",
          "-mod=readonly",
          "-trimpath",
          "-ldflags",
          "-s -w -X main.version=#{version}",
          "-o",
          destination,
          "./cmd/robine-runner"
        ],
        cd: Path.join(File.cwd!(), "runner-go"),
        env: [{"CGO_ENABLED", "0"}, {"GOOS", "linux"}, {"GOARCH", architecture}],
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.raise("bundled Go runner build failed for linux/#{architecture}: #{output}")
    end

    File.chmod!(destination, 0o755)
  end

  defp go_architecture!(architecture) do
    cond do
      String.starts_with?(architecture, "x86_64") -> "amd64"
      String.starts_with?(architecture, "aarch64") -> "arm64"
      String.starts_with?(architecture, "arm64") -> "arm64"
      true -> Mix.raise("unsupported bundled Go runner architecture: #{architecture}")
    end
  end

  defp release_platform! do
    values =
      "/etc/os-release"
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, values ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> Map.put(values, key, String.trim(value, "\""))
          _invalid -> values
        end
      end)

    case {values["ID"], values["VERSION_ID"]} do
      {"ubuntu", version} when version in ["24.04", "26.04"] ->
        %{id: "ubuntu", version: version, runtime_image: "ubuntu:#{version}"}

      {id, version} ->
        Mix.raise(
          "server releases must be built on supported Ubuntu 24.04 or 26.04, got " <>
            "#{inspect(id)} #{inspect(version)}"
        )
    end
  end

  defp write_release_platform(release_root, platform, architecture) do
    content = """
    ROBINE_RELEASE_OS=#{platform.id}
    ROBINE_RELEASE_OS_VERSION=#{platform.version}
    ROBINE_RELEASE_ARCH=#{architecture}
    ROBINE_RUNTIME_IMAGE=#{platform.runtime_image}
    """

    File.write(Path.join(release_root, "RELEASE_PLATFORM"), content, [:binary])
  end
end
