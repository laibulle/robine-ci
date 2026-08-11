defmodule Robine.Pipelines.Domain.BuildProvenanceTest do
  use ExUnit.Case, async: true

  alias Robine.Pipelines.Domain.{BuildProvenance, Pipeline}

  test "creates an authoritative tag build environment" do
    pipeline = %Pipeline{
      id: "9ce783f1-3cf2-4658-9647-1cab33e50745",
      repository_id: "17c78df0-bb10-46d6-9176-004cf068c56c",
      workflow_name: "Release",
      commit_sha: String.duplicate("a", 40),
      source_ref: "v1.2.3",
      trigger: "tag",
      actor: "github:maintainer",
      correlation_id: "build-provenance",
      status: :running,
      inserted_at: ~U[2026-08-11 20:00:00.000000Z],
      started_at: ~U[2026-08-11 20:01:02.123456Z]
    }

    assert BuildProvenance.environment(pipeline) == %{
             "ROBINE_BUILD_COMMIT_SHA" => String.duplicate("a", 40),
             "ROBINE_BUILD_REF_NAME" => "v1.2.3",
             "ROBINE_BUILD_REF_TYPE" => "tag",
             "ROBINE_BUILD_TIMESTAMP" => "2026-08-11T20:01:02.123456Z",
             "ROBINE_BUILD_PIPELINE_ID" => pipeline.id,
             "ROBINE_BUILD_TRIGGER" => "tag"
           }
  end

  test "falls back to pipeline creation time and classifies branches" do
    pipeline = %Pipeline{
      id: Ecto.UUID.generate(),
      repository_id: Ecto.UUID.generate(),
      workflow_name: "CI",
      commit_sha: String.duplicate("b", 40),
      source_ref: "main",
      trigger: "push",
      actor: "github:developer",
      correlation_id: "build-provenance",
      status: :queued,
      inserted_at: ~U[2026-08-11 21:00:00.000000Z]
    }

    environment = BuildProvenance.environment(pipeline)
    assert environment["ROBINE_BUILD_REF_TYPE"] == "branch"
    assert environment["ROBINE_BUILD_TIMESTAMP"] == "2026-08-11T21:00:00.000000Z"
  end
end
