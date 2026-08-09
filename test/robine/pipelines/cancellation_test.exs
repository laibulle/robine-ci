defmodule Robine.Pipelines.CancellationTest do
  use Robine.DataCase, async: false

  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.Job
  alias Robine.{Pipelines, Repo}
  alias Robine.Runtime.Dependencies

  test "durably cancels undispatched jobs and marks active work for runner cancellation" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "cancel-live")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "CI",
                 commit_sha: String.duplicate("c", 40),
                 jobs: %{
                   "build" => %{needs: []},
                   "test" => %{needs: ["build"]}
                 }
               },
               context
             )

    assert {:ok, _} = Pipelines.queue_pipeline(%{pipeline_id: pipeline.id}, context)
    assert {:ok, attempt} = Pipelines.claim_next_job(%{}, context)
    advance(attempt, 1, :preparing, context)
    advance(attempt, 2, :running, context)

    assert {:ok, %{status: :cancelling}} =
             Pipelines.cancel_pipeline(%{pipeline_id: pipeline.id}, context)

    jobs = Repo.all(from job in Job, where: job.pipeline_id == ^pipeline.id)
    assert Enum.find(jobs, &(&1.job_key == "build")).status == :cancelling
    assert Enum.find(jobs, &(&1.job_key == "test")).status == :cancelled

    assert {:ok, true} =
             Pipelines.cancellation_requested(
               %{idempotency_token: attempt.idempotency_token},
               context
             )

    advance(attempt, 3, :cancelled, context, :cancelled)

    assert {:ok, %{status: :cancelled}} =
             Pipelines.pipeline_snapshot(%{pipeline_id: pipeline.id}, context)
  end

  defp advance(attempt, sequence, status, context, reason \\ nil) do
    input = %{idempotency_token: attempt.idempotency_token, sequence: sequence, status: status}
    input = if reason, do: Map.put(input, :reason, reason), else: input
    assert {:ok, _} = Pipelines.record_runner_event(input, context)
  end
end
