defmodule Robine.Adapters.Background.OutboxDeliveryWorkerTest do
  use Robine.DataCase, async: true
  use Oban.Testing, repo: Robine.Repo

  import Ecto.Query

  alias Robine.Adapters.Background.OutboxDeliveryWorker
  alias Robine.Adapters.Persistence.Postgres.Schemas.{OutboxEvent, Pipeline}
  alias Robine.Pipelines
  alias Robine.Runtime.Dependencies
  alias Robine.Repo

  test "delivers pipeline.created through the facade and is idempotent" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "create")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "CI",
                 commit_sha: String.duplicate("c", 40)
               },
               context
             )

    event = Repo.one!(from event in OutboxEvent, where: event.aggregate_id == ^pipeline.id)
    job = Repo.one!(from job in Oban.Job, where: job.args["event_id"] == ^event.id)

    assert :ok = perform_job(OutboxDeliveryWorker, job.args)
    assert Repo.get!(Pipeline, pipeline.id).status == :queued
    assert %DateTime{} = Repo.get!(OutboxEvent, event.id).delivered_at

    assert :ok = perform_job(OutboxDeliveryWorker, job.args)
    assert Repo.get!(Pipeline, pipeline.id).status == :queued
  end

  test "cancellation commits an idempotent projection event without dispatching work" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "cancel-outbox")

    {:ok, pipeline} =
      Pipelines.create_pipeline(
        %{
          repository_id: Ecto.UUID.generate(),
          workflow_name: "CI",
          commit_sha: String.duplicate("d", 40)
        },
        context
      )

    created =
      Repo.one!(
        from event in OutboxEvent,
          where: event.aggregate_id == ^pipeline.id and event.event_type == "pipeline.created"
      )

    assert :ok = perform_job(OutboxDeliveryWorker, %{"event_id" => created.id})

    runner_worker = "Robine.Adapters.Background.RunNextJobWorker"

    dispatch_count =
      Repo.aggregate(from(job in Oban.Job, where: job.worker == ^runner_worker), :count)

    assert {:ok, %{status: :cancelled}} =
             Pipelines.cancel_pipeline(%{pipeline_id: pipeline.id}, context)

    projection =
      Repo.one!(
        from event in OutboxEvent,
          where:
            event.aggregate_id == ^pipeline.id and
              event.event_type == "pipeline.projection_requested"
      )

    assert projection.payload["dispatch"] == false
    assert :ok = perform_job(OutboxDeliveryWorker, %{"event_id" => projection.id})
    assert :ok = perform_job(OutboxDeliveryWorker, %{"event_id" => projection.id})
    assert %DateTime{} = Repo.get!(OutboxEvent, projection.id).delivered_at

    assert Repo.aggregate(from(job in Oban.Job, where: job.worker == ^runner_worker), :count) ==
             dispatch_count
  end

  test "reconciliation recreates a missing delivery job exactly once" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "outbox-recovery")

    {:ok, pipeline} =
      Pipelines.create_pipeline(
        %{
          repository_id: Ecto.UUID.generate(),
          workflow_name: "CI",
          commit_sha: String.duplicate("e", 40)
        },
        context
      )

    event = Repo.one!(from event in OutboxEvent, where: event.aggregate_id == ^pipeline.id)
    delivery_job = Repo.one!(from job in Oban.Job, where: job.args["event_id"] == ^event.id)
    Repo.delete!(delivery_job)

    assert {:ok, 1} = Pipelines.reconcile_outbox(%{}, context)
    assert {:ok, 0} = Pipelines.reconcile_outbox(%{}, context)

    recovered = Repo.one!(from job in Oban.Job, where: job.args["event_id"] == ^event.id)
    assert :ok = perform_job(OutboxDeliveryWorker, recovered.args)
    assert %DateTime{} = Repo.get!(OutboxEvent, event.id).delivered_at
  end

  test "delivery retry backoff is exponential and capped" do
    assert OutboxDeliveryWorker.backoff(%Oban.Job{attempt: 1}) in 15..25
    assert OutboxDeliveryWorker.backoff(%Oban.Job{attempt: 5}) in 240..250
    assert OutboxDeliveryWorker.backoff(%Oban.Job{attempt: 20}) in 1_790..1_800
  end
end
