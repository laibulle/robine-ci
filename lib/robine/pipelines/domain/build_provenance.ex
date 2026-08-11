defmodule Robine.Pipelines.Domain.BuildProvenance do
  @moduledoc "Produces the authoritative, non-secret build environment for a pipeline."

  alias Robine.Pipelines.Domain.Pipeline

  @environment_names [
    "ROBINE_BUILD_COMMIT_SHA",
    "ROBINE_BUILD_REF_NAME",
    "ROBINE_BUILD_REF_TYPE",
    "ROBINE_BUILD_TIMESTAMP",
    "ROBINE_BUILD_PIPELINE_ID",
    "ROBINE_BUILD_TRIGGER"
  ]

  @spec environment_names() :: [String.t()]
  def environment_names, do: @environment_names

  @spec environment(Pipeline.t()) :: %{String.t() => String.t()}
  def environment(%Pipeline{} = pipeline) do
    %{
      "ROBINE_BUILD_COMMIT_SHA" => pipeline.commit_sha,
      "ROBINE_BUILD_REF_NAME" => pipeline.source_ref || "",
      "ROBINE_BUILD_REF_TYPE" => ref_type(pipeline.trigger, pipeline.source_ref),
      "ROBINE_BUILD_TIMESTAMP" =>
        DateTime.to_iso8601(pipeline.started_at || pipeline.inserted_at),
      "ROBINE_BUILD_PIPELINE_ID" => pipeline.id,
      "ROBINE_BUILD_TRIGGER" => to_string(pipeline.trigger)
    }
  end

  defp ref_type(trigger, _source_ref) when trigger in [:tag, "tag"], do: "tag"

  defp ref_type(trigger, _source_ref)
       when trigger in [:pull_request, "pull_request", :merge_request, "merge_request"],
       do: "pull_request"

  defp ref_type(_trigger, source_ref) when is_binary(source_ref) and source_ref != "",
    do: "branch"

  defp ref_type(_trigger, _source_ref), do: "unknown"
end
