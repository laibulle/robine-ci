defmodule Robine.Pipelines.RestartRecoveryTest do
  use Robine.DataCase, async: false

  alias Robine.Pipelines
  alias Robine.Runtime.Dependencies

  test "a fresh runtime dependency graph recovers accepted pipeline state" do
    before_restart =
      Dependencies.context(%{id: "admin", role: :administrator}, "before-restart")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Restart-safe CI",
                 commit_sha: String.duplicate("9", 40),
                 jobs: %{"test" => %{needs: []}}
               },
               before_restart
             )

    assert {:ok, %{status: :queued}} =
             Pipelines.queue_pipeline(%{pipeline_id: pipeline.id}, before_restart)

    after_restart =
      Dependencies.context(%{id: "admin", role: :administrator}, "after-restart")

    assert {:ok, snapshot} =
             Pipelines.pipeline_snapshot(%{pipeline_id: pipeline.id}, after_restart)

    assert snapshot.id == pipeline.id
    assert snapshot.status == :queued
    assert [%{job_key: "test", status: :queued}] = snapshot.jobs
    refute before_restart.correlation_id == after_restart.correlation_id
  end
end
