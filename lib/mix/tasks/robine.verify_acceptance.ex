defmodule Mix.Tasks.Robine.VerifyAcceptance do
  use Mix.Task

  @shortdoc "Verifies external MVP acceptance evidence"

  @impl Mix.Task
  def run(arguments) do
    {options, positional, invalid} =
      OptionParser.parse(arguments,
        strict: [
          first_pipeline: :string,
          accessibility: :string,
          artifact_manifest: :string,
          format: :string
        ]
      )

    if invalid != [] or positional != [] do
      usage!()
    end

    first_pipeline = options[:first_pipeline] || usage!()
    accessibility = options[:accessibility] || usage!()
    artifact_manifest = options[:artifact_manifest] || usage!()
    format = options[:format] || "human"

    unless format in ~w(human json), do: usage!()

    case Robine.Release.AcceptanceEvidence.verify_files(
           first_pipeline,
           accessibility,
           artifact_manifest
         ) do
      {:ok, report} -> print_report(report, format)
      {:error, reason} -> Mix.raise("external acceptance evidence failed: #{inspect(reason)}")
    end
  end

  defp print_report(report, "json") do
    Mix.shell().info(Jason.encode!(report))
  end

  defp print_report(report, "human") do
    Mix.shell().info("External MVP acceptance evidence passed")

    Mix.shell().info(
      "First pipeline: #{report.first_pipeline.measured_seconds}s measured " <>
        "(#{report.first_pipeline.excluded_seconds}s excluded)"
    )

    Mix.shell().info(
      "Accessibility: #{length(report.accessibility.journeys)} journeys with " <>
        report.accessibility.screen_reader
    )
  end

  defp usage! do
    Mix.raise(
      "usage: mix robine.verify_acceptance " <>
        "--first-pipeline FILE --accessibility FILE --artifact-manifest FILE " <>
        "[--format human|json]"
    )
  end
end
