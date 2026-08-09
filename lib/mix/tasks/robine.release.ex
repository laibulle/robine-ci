defmodule Mix.Tasks.Robine.Release do
  use Mix.Task

  @shortdoc "Builds the versioned Robine escript and SHA256SUMS"

  @impl Mix.Task
  def run(arguments) do
    unless Mix.env() == :cli do
      Mix.raise("robine.release must run in its isolated CLI environment; unset MIX_ENV")
    end

    {options, positional, invalid} =
      OptionParser.parse(arguments, strict: [output: :string], aliases: [o: :output])

    if invalid != [] or positional != [] do
      Mix.raise("usage: mix robine.release [--output DIRECTORY]")
    end

    output = Path.expand(options[:output] || "dist")
    version = Mix.Project.config() |> Keyword.fetch!(:version)
    Mix.Task.run("escript.build")

    case Robine.Release.Package.create(Path.expand("robine"), output, version) do
      {:ok, %{artifact: artifact, manifest: manifest}} ->
        Mix.shell().info("Created #{artifact}")
        Mix.shell().info("Created #{manifest}")

      {:error, reason} ->
        Mix.raise("release packaging failed: #{inspect(reason)}")
    end
  end
end
