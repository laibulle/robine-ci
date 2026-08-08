defmodule Robine.Pipelines.Domain.LifecycleTest do
  use ExUnit.Case, async: true

  alias Robine.Pipelines.Domain.{Attempt, Job, Pipeline, Step}

  test "pipeline transition and cancellation rules are explicit" do
    pipeline = pipeline(:created)

    assert {:ok, %{status: :queued} = queued} = Pipeline.transition(pipeline, :queued)
    assert {:ok, %{status: :running} = running} = Pipeline.transition(queued, :running)
    assert {:ok, %{status: :cancelling}} = Pipeline.request_cancellation(running)

    assert {:error, {:invalid_transition, :pipeline, :created, :succeeded}} =
             Pipeline.transition(pipeline, :succeeded)

    assert {:error, {:pipeline_terminal, :succeeded}} =
             Pipeline.request_cancellation(pipeline(:succeeded))
  end

  test "pipeline derives its terminal result from terminal jobs" do
    succeeded = job(:succeeded)
    skipped = %{job(:skipped) | id: "skipped", job_key: "skipped"}

    assert {:ok, %{status: :succeeded}} =
             Pipeline.complete_from_jobs(pipeline(:running), [succeeded, skipped])

    assert {:ok, %{status: :failed}} =
             Pipeline.complete_from_jobs(pipeline(:running), [job(:failed), skipped])
  end

  test "jobs release only after dependencies succeed and skip after dependency failure" do
    assert {:ok, blocked} =
             Job.new(%{
               id: "job",
               pipeline_id: "pipeline",
               job_key: "test",
               needs: ["build"],
               position: 1
             })

    assert blocked.status == :blocked
    assert {:ok, %{status: :blocked}} = Job.release(blocked, %{"build" => :running})
    assert {:ok, %{status: :queued}} = Job.release(blocked, %{"build" => :succeeded})
    assert {:ok, %{status: :skipped}} = Job.release(blocked, %{"build" => :failed})
  end

  test "attempt events are ordered, idempotent, and classify failures" do
    assert {:ok, attempt} =
             Attempt.new(%{
               id: "attempt",
               job_id: "job",
               number: 1,
               idempotency_token: "token",
               lease_expires_at: ~U[2026-08-08 12:05:00Z]
             })

    assert {:ok, preparing} = Attempt.record_event(attempt, 1, :preparing)
    assert {:ok, ^preparing} = Attempt.record_event(preparing, 1, :preparing)
    assert {:error, {:event_gap, 2, 3}} = Attempt.record_event(preparing, 3, :running)
    assert {:ok, running} = Attempt.record_event(preparing, 2, :running)
    assert {:ok, failed} = Attempt.record_event(running, 3, :failed, :timeout)
    assert failed.result_reason == :timeout
    assert Attempt.lease_expired?(failed, ~U[2026-08-08 12:06:00Z])
  end

  test "step exit codes agree with terminal status" do
    step = %Step{id: "step", attempt_id: "attempt", name: "Test", position: 0, status: :pending}

    assert {:ok, running} = Step.transition(step, :running)
    assert {:ok, %{status: :succeeded, exit_code: 0}} = Step.transition(running, :succeeded, 0)

    assert {:error, {:invalid_transition, :step, :running, :succeeded}} =
             Step.transition(running, :succeeded, 1)
  end

  defp pipeline(status) do
    %Pipeline{
      id: "pipeline",
      repository_id: "repository",
      workflow_name: "CI",
      commit_sha: String.duplicate("a", 40),
      status: status,
      inserted_at: ~U[2026-08-08 12:00:00Z]
    }
  end

  defp job(status) do
    %Job{
      id: "job",
      pipeline_id: "pipeline",
      job_key: "job",
      status: status,
      needs: [],
      position: 0
    }
  end
end
