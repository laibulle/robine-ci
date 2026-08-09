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
    architecture = :erlang.system_info(:system_architecture) |> to_string() |> sanitize()
    artifact_name = "robine-server-#{version}-#{architecture}.tar.gz"
    artifact = Path.join(output, artifact_name)
    temporary = artifact <> ".tmp-#{System.unique_integer([:positive])}"

    Mix.Task.run("assets.deploy")
    Mix.Task.run("release", ["--overwrite"])

    release_root = Path.join([Mix.Project.build_path(), "rel", "robine"])

    try do
      with false <- File.exists?(artifact),
           :ok <- File.mkdir_p(output),
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
end
