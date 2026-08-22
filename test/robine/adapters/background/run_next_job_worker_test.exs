defmodule Robine.Adapters.Background.RunNextJobWorkerTest do
  use Robine.DataCase, async: false
  use Oban.Testing, repo: Robine.Repo

  import Ecto.Query

  alias Robine.Adapters.Background.{OutboxDeliveryWorker, RunNextJobWorker}
  alias Robine.Adapters.Persistence.Postgres.Schemas.{Attempt, LogChunk, Pipeline}
  alias Robine.Pipelines
  alias Robine.Runtime.Dependencies
  alias Robine.Secrets
  alias Robine.Repo

  @tag :docker
  test "executes a persisted job through the Execution facade and completes its pipeline" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "runner-e2e")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "CI",
                 commit_sha: String.duplicate("1", 40),
                 jobs: %{
                   "test" => %{
                     needs: [],
                     image: "postgres:18-alpine",
                     env: %{"GREETING" => "hello"},
                     timeout_ms: 20_000,
                     shell: "/bin/sh",
                     steps: [
                       %{name: "Test", kind: :run, value: "printf '%s robine' \"$GREETING\""}
                     ]
                   }
                 }
               },
               context
             )

    outbox_job = Repo.one!(from job in Oban.Job, where: job.queue == "outbox")
    assert :ok = perform_job(OutboxDeliveryWorker, outbox_job.args)

    scheduler_job =
      Repo.one!(from job in Oban.Job, where: job.worker == ^inspect(RunNextJobWorker))

    assert :ok = perform_job(RunNextJobWorker, scheduler_job.args)

    assert Repo.get!(Pipeline, pipeline.id).status == :succeeded
    assert Repo.one!(Attempt).status == :succeeded
    chunks = Repo.all(from chunk in LogChunk, order_by: [asc: chunk.sequence])

    assert Enum.any?(
             chunks,
             &(&1.phase == "image_acquisition" and &1.step_name == "Image acquisition" and
                 &1.step_status == "succeeded")
           )

    command_chunks = Enum.filter(chunks, &(&1.step_name == "Test"))
    assert Enum.all?(command_chunks, &(&1.phase == "execution"))
    assert Enum.map_join(command_chunks, & &1.content) == "hello robine"
    assert Enum.map(command_chunks, & &1.step_status) == ["running", "succeeded"]
  end

  @tag :docker
  test "resolves only declared secrets immediately before runner dispatch" do
    repository_id = Ecto.UUID.generate()
    context = Dependencies.context(%{id: "admin", role: :administrator}, "secret-runner")

    assert {:ok, _metadata} =
             Secrets.store_secret(
               %{
                 name: "TOKEN",
                 value: "unpersisted-secret-value",
                 scope: :repository,
                 repository_id: repository_id
               },
               context
             )

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: repository_id,
                 workflow_name: "CI",
                 commit_sha: String.duplicate("2", 40),
                 jobs: %{
                   "test" => %{
                     needs: [],
                     image: "postgres:18-alpine",
                     secrets: ["TOKEN"],
                     steps: [
                       %{
                         name: "Check",
                         kind: :run,
                         value: "test -n \"$TOKEN\""
                       }
                     ]
                   }
                 }
               },
               context
             )

    outbox_job =
      Repo.one!(from job in Oban.Job, where: job.queue == "outbox", order_by: [desc: job.id])

    assert :ok = perform_job(OutboxDeliveryWorker, outbox_job.args)

    scheduler_job =
      Repo.one!(
        from job in Oban.Job,
          where: job.worker == ^inspect(RunNextJobWorker),
          order_by: [desc: job.id]
      )

    assert :ok = perform_job(RunNextJobWorker, scheduler_job.args)
    assert Repo.get!(Pipeline, pipeline.id).status == :succeeded

    persisted_job = Repo.one!(from(job in Robine.Adapters.Persistence.Postgres.Schemas.Job))
    refute inspect(persisted_job.execution_spec) =~ "unpersisted-secret-value"
  end

  test "persists an actionable diagnostic when a declared secret is missing" do
    repository_id = Ecto.UUID.generate()
    context = Dependencies.context(%{id: "admin", role: :administrator}, "missing-secret-runner")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: repository_id,
                 workflow_name: "CI",
                 commit_sha: String.duplicate("3", 40),
                 jobs: %{
                   "test" => %{
                     needs: [],
                     image: "postgres:18-alpine",
                     secrets: ["MISSING_TOKEN"],
                     steps: [%{name: "Check", kind: :run, value: "test -n \"$MISSING_TOKEN\""}]
                   }
                 }
               },
               context
             )

    outbox_job =
      Repo.one!(from job in Oban.Job, where: job.queue == "outbox", order_by: [desc: job.id])

    assert :ok = perform_job(OutboxDeliveryWorker, outbox_job.args)

    scheduler_job =
      Repo.one!(
        from job in Oban.Job,
          where: job.worker == ^inspect(RunNextJobWorker),
          order_by: [desc: job.id]
      )

    assert {:error, {:secrets_missing, ["MISSING_TOKEN"]}} =
             perform_job(RunNextJobWorker, scheduler_job.args)

    attempt = Repo.one!(Attempt)
    assert attempt.status == :failed
    assert attempt.result_reason == :system_failure
    assert attempt.last_sequence == 2
    assert Repo.get!(Pipeline, pipeline.id).status == :failed

    diagnostic = Repo.one!(LogChunk)
    assert diagnostic.phase == "execution"
    assert diagnostic.stream == "system"
    assert diagnostic.step_name == "Job preparation"
    assert diagnostic.step_status == "failed"

    assert diagnostic.content ==
             "Required CI secret is unavailable: MISSING_TOKEN. Add it in repository secrets, then retry the job."

    assert {:ok, snapshot} =
             Pipelines.pipeline_snapshot(%{pipeline_id: pipeline.id}, context)

    assert hd(snapshot.jobs).failure_detail == diagnostic.content
  end
end
