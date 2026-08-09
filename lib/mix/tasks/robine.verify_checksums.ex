defmodule Mix.Tasks.Robine.VerifyChecksums do
  use Mix.Task

  @shortdoc "Verifies a Robine SHA256SUMS release manifest"

  @impl Mix.Task
  def run(arguments) do
    {options, positional, invalid} =
      OptionParser.parse(arguments, strict: [directory: :string], aliases: [d: :directory])

    if invalid != [] or positional != [] do
      Mix.raise("usage: mix robine.verify_checksums [--directory DIRECTORY]")
    end

    directory = Path.expand(options[:directory] || "dist")

    case Robine.Release.Checksums.verify(Path.join(directory, "SHA256SUMS"), directory) do
      :ok -> Mix.shell().info("Checksums verified for #{directory}")
      {:error, reason} -> Mix.raise("checksum verification failed: #{inspect(reason)}")
    end
  end
end
