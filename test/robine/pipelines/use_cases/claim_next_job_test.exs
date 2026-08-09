defmodule Robine.Pipelines.UseCases.ClaimNextJobTest do
  use Robine.DataCase, async: false
  use Oban.Testing, repo: Robine.Repo

  import Ecto.Query

  alias Robine.Adapters.Background.OutboxDeliveryWorker
  alias Robine.Adapters.Persistence.Postgres.Schemas.{Job, Pipeline}
  alias Robine.Pipelines
  alias Robine.Runtime.Dependencies
  alias Robine.Repo

  test "persists a graph and claims only a ready job within capacity" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "graph")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "CI",
                 commit_sha: String.duplicate("d", 40),
                 jobs: %{
                   "build" => %{needs: []},
                   "test" => %{needs: ["build"]}
                 }
               },
               context
             )

    outbox_job = Repo.one!(from job in Oban.Job, where: job.queue == "outbox")
    assert :ok = perform_job(OutboxDeliveryWorker, outbox_job.args)

    assert {:ok, attempt} =
             Pipelines.claim_next_job(
               %{global_limit: 1, repository_limit: 1, lease_seconds: 30},
               context
             )

    build =
      Repo.one!(
        from job in Job, where: job.pipeline_id == ^pipeline.id and job.job_key == "build"
      )

    test_job =
      Repo.one!(from job in Job, where: job.pipeline_id == ^pipeline.id and job.job_key == "test")

    assert attempt.job_id == build.id
    assert build.status == :running
    assert test_job.status == :blocked
    assert Repo.get!(Pipeline, pipeline.id).status == :running

    assert {:error, :capacity} =
             Pipelines.claim_next_job(%{global_limit: 1, repository_limit: 1}, context)
  end

  test "disk pressure refuses admission before creating an attempt or changing job state" do
    previous = Application.fetch_env!(:robine, :runner_admission)

    Application.put_env(:robine, :runner_admission,
      min_free_bytes: 9_223_372_036_854_775_807,
      max_used_percent: 95
    )

    on_exit(fn -> Application.put_env(:robine, :runner_admission, previous) end)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "disk-pressure")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "CI",
                 commit_sha: String.duplicate("e", 40),
                 jobs: %{"build" => %{needs: []}}
               },
               context
             )

    assert {:ok, _} = Pipelines.queue_pipeline(%{pipeline_id: pipeline.id}, context)
    assert {:error, :disk_pressure} = Pipelines.claim_next_job(%{}, context)

    assert %Job{status: :queued} =
             Repo.one!(from job in Job, where: job.pipeline_id == ^pipeline.id)

    assert Repo.aggregate(Robine.Adapters.Persistence.Postgres.Schemas.Attempt, :count) == 0
  end
end
