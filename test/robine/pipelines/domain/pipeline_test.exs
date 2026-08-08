defmodule Robine.Pipelines.Domain.PipelineTest do
  use ExUnit.Case, async: true

  alias Robine.Pipelines.Domain.Pipeline

  @now ~U[2026-08-08 12:00:00.123456Z]
  @id "9ce783f1-3cf2-4658-9647-1cab33e50745"

  test "creates a pipeline from valid attributes" do
    input = %{
      repository_id: "17c78df0-bb10-46d6-9176-004cf068c56c",
      workflow_name: "CI",
      commit_sha: String.duplicate("a", 40)
    }

    assert {:ok, pipeline} = Pipeline.create(input, @id, @now)
    assert pipeline.id == @id
    assert pipeline.status == :created
    assert pipeline.inserted_at == @now
  end

  test "rejects missing attributes and malformed commit SHAs" do
    assert {:error, {:invalid_input, :repository_id, :required}} =
             Pipeline.create(%{}, @id, @now)

    assert {:error, {:invalid_input, :commit_sha, :invalid_sha}} =
             Pipeline.create(
               %{repository_id: "repository", workflow_name: "CI", commit_sha: "main"},
               @id,
               @now
             )
  end
end
