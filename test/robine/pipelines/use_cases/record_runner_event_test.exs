defmodule Robine.Pipelines.UseCases.RecordRunnerEventTest do
  use Robine.DataCase, async: false
  use Oban.Testing, repo: Robine.Repo

  import Ecto.Query

  alias Robine.Adapters.Background.OutboxDeliveryWorker
  alias Robine.Adapters.Persistence.Postgres.Schemas.{Attempt, Job, Pipeline}
  alias Robine.Pipelines
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
