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
end
