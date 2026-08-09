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

  test "pipeline timing starts on execution and finishes on terminal aggregation" do
    started_at = ~U[2026-08-09 12:00:00Z]
    finished_at = DateTime.add(started_at, 75, :second)

    assert {:ok, running} = Pipeline.transition(pipeline(:queued), :running, started_at)
    assert running.started_at == started_at
    assert running.finished_at == nil

    assert {:ok, completed} =
             Pipeline.complete_from_jobs(running, [job(:succeeded)], finished_at)

    assert completed.status == :succeeded
    assert completed.started_at == started_at
    assert completed.finished_at == finished_at
  end

  test "jobs wait for every dependency before evaluating their condition" do
    blocked = conditional_job("success")

    assert {:ok, %{status: :blocked}} =
             Job.release(blocked, %{"build" => :failed, "lint" => :running})

    assert {:ok, %{status: :queued}} =
             Job.release(blocked, %{"build" => :succeeded, "lint" => :succeeded})

    assert {:ok, %{status: :skipped}} =
             Job.release(blocked, %{"build" => :succeeded, "lint" => :failed})
  end

  test "failure and always conditions use dependency terminal outcomes" do
    statuses = %{"build" => :failed, "lint" => :skipped}

    assert {:ok, %{status: :queued}} = Job.release(conditional_job("failure"), statuses)
    assert {:ok, %{status: :queued}} = Job.release(conditional_job("always"), statuses)

    assert {:ok, %{status: :skipped}} =
             Job.release(conditional_job("failure"), %{
               "build" => :succeeded,
               "lint" => :skipped
             })

    assert {:ok, %{status: :queued}} =
             Job.release(conditional_job("always"), %{
               "build" => :succeeded,
               "lint" => :skipped
             })
  end

  test "a cancelled dependency suppresses every condition" do
    statuses = %{"build" => :cancelled, "lint" => :failed}

    for condition <- ["success", "failure", "always"] do
      assert {:ok, %{status: :skipped}} =
               Job.release(conditional_job(condition), statuses)
    end
  end

  test "job condition evaluation is idempotent after release" do
    assert {:ok, queued} =
             Job.release(conditional_job("always"), %{
               "build" => :failed,
               "lint" => :skipped
             })

    assert {:ok, ^queued} =
             Job.release(queued, %{"build" => :succeeded, "lint" => :succeeded})
  end

  test "job construction rejects unknown and independent failure conditions" do
    assert {:error, {:invalid_job_condition, "sometimes"}} =
             Job.new(job_input(["build"], "sometimes"))

    assert {:error, {:invalid_job_condition, "failure"}} =
             Job.new(job_input([], "failure"))
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

  test "heartbeats extend active leases without consuming an event sequence" do
    {:ok, attempt} =
      Attempt.new(%{
        id: "attempt",
        job_id: "job",
        number: 1,
        idempotency_token: "token",
        lease_expires_at: ~U[2026-08-08 12:05:00Z]
      })

    assert {:ok, renewed} = Attempt.heartbeat(attempt, ~U[2026-08-08 12:04:30Z], 120)
    assert renewed.lease_expires_at == ~U[2026-08-08 12:06:30Z]
    assert renewed.last_sequence == attempt.last_sequence

    assert {:ok, ^renewed} = Attempt.heartbeat(renewed, ~U[2026-08-08 12:04:00Z], 60)

    {:ok, terminal} = Attempt.record_event(attempt, 1, :failed, :runner_lost)

    assert {:error, {:attempt_terminal, :failed}} =
             Attempt.heartbeat(terminal, DateTime.utc_now(), 60)
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
      trigger: "manual",
      actor: "developer",
      correlation_id: "domain-test",
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

  defp conditional_job(condition) do
    assert {:ok, job} = Job.new(job_input(["build", "lint"], condition))
    job
  end

  defp job_input(needs, condition) do
    %{
      id: "conditional-job",
      pipeline_id: "pipeline",
      job_key: "test",
      needs: needs,
      position: 1,
      execution: %{"condition" => condition}
    }
  end
end
