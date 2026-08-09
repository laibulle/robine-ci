defmodule Robine.Pipelines.UseCases.RecordRunnerEventTest do
  use Robine.DataCase, async: false
  use Oban.Testing, repo: Robine.Repo

  import Ecto.Query

  alias Robine.Adapters.Background.OutboxDeliveryWorker

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    Attempt,
    Job,
    Pipeline,
    RunnerAttemptEvent
  }

  alias Robine.{Pipelines, Runners}
  alias Robine.Runtime.Dependencies
  alias Robine.Repo

  test "ordered terminal events release dependencies and complete the pipeline" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "events")
    pipeline = create_graph(context)
    deliver_created_event()

    assert {:ok, build_attempt} = Pipelines.claim_next_job(%{}, context)

    assert {:ok, preparing} =
             record(build_attempt, 1, :preparing, nil, context)

    assert {:ok, _running} = record(preparing, 2, :running, nil, context)
    assert {:ok, _succeeded} = record(preparing, 3, :succeeded, nil, context)

    assert Repo.one!(from job in Job, where: job.job_key == "test").status == :queued

    assert {:ok, test_attempt} = Pipelines.claim_next_job(%{}, context)
    assert {:ok, _} = record(test_attempt, 1, :preparing, nil, context)
    assert {:ok, _} = record(test_attempt, 2, :running, nil, context)
    assert {:ok, _} = record(test_attempt, 3, :failed, :command_failed, context)

    assert Repo.get!(Pipeline, pipeline.id).status == :failed

    assert Repo.one!(from attempt in Attempt, where: attempt.id == ^test_attempt.id).result_reason ==
             :command_failed
  end

  test "duplicate runner events do not apply a transition twice" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "duplicates")
    _pipeline = create_graph(context, %{"build" => %{needs: []}})
    deliver_created_event()
    assert {:ok, attempt} = Pipelines.claim_next_job(%{}, context)

    assert {:ok, first} = record(attempt, 1, :preparing, nil, context)
    assert {:ok, duplicate} = record(attempt, 1, :preparing, nil, context)
    assert first == duplicate
  end

  test "terminal dependency snapshots queue matching jobs and durably skip the others" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "conditions")

    pipeline =
      create_graph(context, %{
        "build" => %{needs: []},
        "on-success" => %{needs: ["build"], condition: :success},
        "on-failure" => %{needs: ["build"], condition: :failure},
        "cleanup" => %{needs: ["on-success"], condition: :always}
      })

    deliver_created_event()
    assert {:ok, build_attempt} = Pipelines.claim_next_job(%{}, context)
    assert {:ok, _} = record(build_attempt, 1, :preparing, nil, context)
    assert {:ok, _} = record(build_attempt, 2, :running, nil, context)
    assert {:ok, terminal} = record(build_attempt, 3, :failed, :command_failed, context)

    assert {:ok, ^terminal} =
             record(build_attempt, 3, :failed, :command_failed, context)

    statuses =
      Repo.all(from job in Job, where: job.pipeline_id == ^pipeline.id)
      |> Map.new(&{&1.job_key, &1.status})

    assert statuses == %{
             "build" => :failed,
             "cleanup" => :queued,
             "on-failure" => :queued,
             "on-success" => :skipped
           }

    skipped_job = Repo.one!(from job in Job, where: job.job_key == "on-success")

    assert Repo.aggregate(
             from(attempt in Attempt, where: attempt.job_id == ^skipped_job.id),
             :count
           ) == 0

    assert {:ok, first} = Pipelines.claim_next_job(%{}, context)
    assert {:ok, second} = Pipelines.claim_next_job(%{}, context)

    claimed_keys =
      Repo.all(
        from job in Job, where: job.id in [^first.job_id, ^second.job_id], select: job.job_key
      )

    assert MapSet.new(claimed_keys) == MapSet.new(["cleanup", "on-failure"])
    assert Repo.get!(Pipeline, pipeline.id).status == :running
  end

  test "simultaneous dependency completions release one conditional job without deadlock" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "concurrent-conditions")

    pipeline =
      create_graph(context, %{
        "build" => %{needs: []},
        "lint" => %{needs: []},
        "cleanup" => %{needs: ["build", "lint"], condition: :always}
      })

    deliver_created_event()
    assert {:ok, first} = Pipelines.claim_next_job(%{}, context)
    assert {:ok, second} = Pipelines.claim_next_job(%{}, context)

    attempts = [first, second]

    for attempt <- attempts do
      assert {:ok, _} = record(attempt, 1, :preparing, nil, context)
      assert {:ok, _} = record(attempt, 2, :running, nil, context)
    end

    tasks =
      Enum.map(attempts, fn attempt ->
        Task.async(fn -> record(attempt, 3, :succeeded, nil, context) end)
      end)

    assert Enum.all?(Task.await_many(tasks, 5_000), &match?({:ok, %{status: :succeeded}}, &1))

    cleanup =
      Repo.one!(
        from job in Job, where: job.pipeline_id == ^pipeline.id and job.job_key == "cleanup"
      )

    assert cleanup.status == :queued
    assert {:ok, cleanup_attempt} = Pipelines.claim_next_job(%{}, context)
    assert cleanup_attempt.job_id == cleanup.id
    assert {:error, :none} = Pipelines.claim_next_job(%{}, context)

    assert Repo.aggregate(from(attempt in Attempt, where: attempt.job_id == ^cleanup.id), :count) ==
             1
  end

  test "expanded matrix variants schedule independently before a fan-in job" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "matrix-scheduling")

    document = %{
      "version" => 1,
      "name" => "Matrix",
      "on" => %{"push" => %{}},
      "jobs" => %{
        "test" => %{
          "image" => "alpine:${{ matrix.version }}",
          "strategy" => %{"matrix" => %{"version" => ["3.21", "3.22"]}},
          "steps" => [%{"run" => "true"}]
        },
        "summary" => %{
          "image" => "alpine:3.22",
          "needs" => "test",
          "if" => "failure",
          "steps" => [%{"run" => "true"}]
        }
      }
    }

    assert {:ok, workflow, _warnings} = Robine.Workflows.Domain.Validator.validate(document)

    pipeline =
      create_graph(context, workflow.jobs)

    deliver_created_event()
    assert {:ok, first} = Pipelines.claim_next_job(%{}, context)
    assert {:ok, second} = Pipelines.claim_next_job(%{}, context)

    variant_keys =
      Repo.all(
        from job in Job, where: job.id in [^first.job_id, ^second.job_id], select: job.job_key
      )

    assert MapSet.new(variant_keys) ==
             MapSet.new(["test[version=3.21]", "test[version=3.22]"])

    for attempt <- [first, second] do
      assert {:ok, _} = record(attempt, 1, :preparing, nil, context)
      assert {:ok, _} = record(attempt, 2, :running, nil, context)
    end

    assert {:ok, _} = record(first, 3, :succeeded, nil, context)

    assert Repo.one!(
             from job in Job, where: job.pipeline_id == ^pipeline.id and job.job_key == "summary"
           ).status == :blocked

    assert {:ok, _} = record(second, 3, :failed, :command_failed, context)

    summary =
      Repo.one!(
        from job in Job, where: job.pipeline_id == ^pipeline.id and job.job_key == "summary"
      )

    assert summary.status == :queued
    assert {:ok, summary_attempt} = Pipelines.claim_next_job(%{}, context)
    assert summary_attempt.job_id == summary.id
    assert {:error, :none} = Pipelines.claim_next_job(%{}, context)
  end

  test "remote runner messages are assigned, durable, idempotent, and reconciled" do
    admin_context = Dependencies.context(%{id: "admin", role: :administrator}, "remote-events")

    anonymous_context =
      Dependencies.context(%{id: "anonymous", role: :runner}, "remote-events")

    assert {:ok, enrollment} = Runners.create_enrollment_token(%{}, admin_context)

    assert {:ok, identity} =
             Runners.enroll(%{token: enrollment.token, name: "event-runner"}, anonymous_context)

    runner_id = identity.runner_id
    runner_context = Dependencies.context(%{id: runner_id, role: :runner}, "remote-events")

    assert {:ok, _welcome} =
             Runners.negotiate_protocol(
               %{
                 supported_protocol_versions: [1],
                 software_version: "0.2.0-dev",
                 capabilities: %{"docker" => true, "concurrency" => 1}
               },
               runner_context
             )

    _pipeline = create_graph(admin_context, %{"build" => %{needs: []}})
    deliver_created_event()

    assert {:ok, attempt} = Pipelines.claim_next_job(%{runner_id: runner_id}, admin_context)
    assert attempt.runner_id == runner_id

    message_id = Ecto.UUID.generate()

    event = %{
      idempotency_token: attempt.idempotency_token,
      message_id: message_id,
      sequence: 1,
      status: :preparing,
      reason: nil
    }

    assert {:ok, first} = Pipelines.record_runner_event(event, runner_context)
    assert first.last_sequence == 1
    assert {:ok, duplicate} = Pipelines.record_runner_event(event, runner_context)
    assert duplicate.last_sequence == 1
    assert Repo.aggregate(RunnerAttemptEvent, :count) == 1

    assert {:error, :message_id_conflict} =
             Pipelines.record_runner_event(%{event | status: :running}, runner_context)

    assert {:error, {:event_gap, 2, 3}} =
             Pipelines.record_runner_event(
               %{event | message_id: Ecto.UUID.generate(), sequence: 3, status: :running},
               runner_context
             )

    assert {:error, :attempt_not_assigned_to_runner} =
             Pipelines.record_runner_event(
               %{event | message_id: Ecto.UUID.generate()},
               Dependencies.context(%{id: Ecto.UUID.generate(), role: :runner}, "intruder")
             )

    assert {:ok, running} =
             Pipelines.record_runner_event(
               %{event | message_id: Ecto.UUID.generate(), sequence: 2, status: :running},
               runner_context
             )

    assert running.last_sequence == 2
    lost_id = Ecto.UUID.generate()

    assert {:ok, reconciliation} =
             Pipelines.reconcile_runner_attempts(
               %{active_attempt_ids: [attempt.id, lost_id]},
               runner_context
             )

    assert reconciliation.resume == [%{attempt_id: attempt.id, acknowledged_sequence: 2}]
    assert reconciliation.lease_lost == [lost_id]
  end

  defp record(attempt, sequence, status, reason, context) do
    Pipelines.record_runner_event(
      %{
        idempotency_token: attempt.idempotency_token,
        sequence: sequence,
        status: status,
        reason: reason
      },
      context
    )
  end

  defp create_graph(context, jobs \\ %{"build" => %{needs: []}, "test" => %{needs: ["build"]}}) do
    {:ok, pipeline} =
      Pipelines.create_pipeline(
        %{
          repository_id: Ecto.UUID.generate(),
          workflow_name: "CI",
          commit_sha: String.duplicate("e", 40),
          jobs: jobs
        },
        context
      )

    pipeline
  end

  defp deliver_created_event do
    job = Repo.one!(from job in Oban.Job, where: job.queue == "outbox")
    assert :ok = perform_job(OutboxDeliveryWorker, job.args)
  end
end
