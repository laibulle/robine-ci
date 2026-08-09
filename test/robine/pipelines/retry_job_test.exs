defmodule Robine.Pipelines.RetryJobTest do
  use Robine.DataCase, async: false

  alias Robine.Pipelines
  alias Robine.Storage
  alias Robine.Adapters.Storage.LocalBlobStore
  alias Robine.Runtime.Dependencies

  test "reopens a failed pipeline and queues a new attempt for the selected job" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "retry")
    {pipeline, attempt} = failed_pipeline(context, [%{name: "Test", kind: :run, value: "false"}])

    assert {:ok, %{job_id: job_id, pipeline_id: pipeline_id, status: :queued}} =
             Pipelines.retry_job(%{job_id: attempt.job_id}, context)

    assert pipeline_id == pipeline.id
    assert job_id == attempt.job_id

    assert {:ok, %{status: :running}} =
             Pipelines.pipeline_snapshot(%{pipeline_id: pipeline.id}, context)

    assert {:ok, next_attempt} = Pipelines.claim_next_job(%{}, context)
    assert next_attempt.job_id == attempt.job_id
    assert next_attempt.number == 2
  end

  test "refuses a narrow retry when artifact inputs cannot be proven retained" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "retry-artifacts")
    {_pipeline, attempt, _build_attempt} = failed_downstream(context, false)

    assert {:error,
            {:retry_inputs_unavailable, %{inputs: ["build/release"], rerun_jobs: ["build"]}}} =
             Pipelines.retry_job(%{job_id: attempt.job_id}, context)
  end

  test "allows a narrow retry while dependency artifacts are retained" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "retry-retained")
    {_pipeline, attempt, build_attempt} = failed_downstream(context, true)

    assert {:ok, %{job_id: job_id, status: :queued}} =
             Pipelines.retry_job(%{job_id: attempt.job_id}, context)

    assert job_id == attempt.job_id

    artifact =
      Robine.Repo.get_by!(Robine.Adapters.Persistence.Postgres.Schemas.Artifact,
        attempt_id: build_attempt.id,
        name: "release"
      )

    assert :ok = LocalBlobStore.delete(artifact.blob_id)
  end

  test "atomically requeues the minimal producer and blocks the target until it succeeds" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "rerun-producer")
    {pipeline, attempt, build_attempt} = failed_downstream(context, false)

    assert {:ok,
            %{
              job_id: target_id,
              status: :blocked,
              rerun_jobs: ["build"],
              pipeline_id: pipeline_id
            }} =
             Pipelines.retry_job(
               %{job_id: attempt.job_id, rerun_dependencies: true},
               context
             )

    assert target_id == attempt.job_id
    assert pipeline_id == pipeline.id

    assert {:ok, producer_attempt} = Pipelines.claim_next_job(%{}, context)
    assert producer_attempt.job_id == build_attempt.job_id
    assert producer_attempt.number == 2

    assert {:ok, snapshot} = Pipelines.pipeline_snapshot(%{pipeline_id: pipeline.id}, context)
    assert Enum.find(snapshot.jobs, &(&1.job_key == "test")).status == :blocked
  end

  defp failed_downstream(context, upload?) do
    repository_id = Ecto.UUID.generate()

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: repository_id,
                 workflow_name: "CI",
                 commit_sha: String.duplicate("8", 40),
                 jobs: %{
                   "build" => %{
                     needs: [],
                     image: "alpine",
                     steps: [%{name: "Build", kind: :run, value: "true"}]
                   },
                   "test" => %{
                     needs: ["build"],
                     image: "alpine",
                     steps: [
                       %{
                         name: "Download",
                         kind: :builtin,
                         value: "artifacts/download",
                         with: %{"name" => "release", "from" => "build", "path" => "."}
                       }
                     ]
                   }
                 }
               },
               context
             )

    assert {:ok, _} = Pipelines.queue_pipeline(%{pipeline_id: pipeline.id}, context)
    assert {:ok, build_attempt} = Pipelines.claim_next_job(%{}, context)
    advance(build_attempt, 1, :preparing, context)
    advance(build_attempt, 2, :running, context)

    if upload? do
      assert {:ok, _artifact} =
               Storage.upload_artifact(
                 %{
                   repository_id: repository_id,
                   attempt_id: build_attempt.id,
                   name: "release",
                   content: "retained"
                 },
                 context
               )
    end

    advance(build_attempt, 3, :succeeded, context)
    assert {:ok, test_attempt} = Pipelines.claim_next_job(%{}, context)
    advance(test_attempt, 1, :preparing, context)
    advance(test_attempt, 2, :running, context)
    advance(test_attempt, 3, :failed, context, :command_failed)
    {pipeline, test_attempt, build_attempt}
  end

  defp advance(attempt, sequence, status, context, reason \\ nil) do
    input = %{idempotency_token: attempt.idempotency_token, sequence: sequence, status: status}
    input = if reason, do: Map.put(input, :reason, reason), else: input
    assert {:ok, _} = Pipelines.record_runner_event(input, context)
  end

  defp failed_pipeline(context, steps) do
    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "CI",
                 commit_sha: String.duplicate("9", 40),
                 jobs: %{"test" => %{needs: [], image: "alpine:3.22", steps: steps}}
               },
               context
             )

    assert {:ok, _queued} = Pipelines.queue_pipeline(%{pipeline_id: pipeline.id}, context)
    assert {:ok, attempt} = Pipelines.claim_next_job(%{}, context)

    assert {:ok, _} =
             Pipelines.record_runner_event(
               %{idempotency_token: attempt.idempotency_token, sequence: 1, status: :preparing},
               context
             )

    assert {:ok, _} =
             Pipelines.record_runner_event(
               %{idempotency_token: attempt.idempotency_token, sequence: 2, status: :running},
               context
             )

    assert {:ok, _} =
             Pipelines.record_runner_event(
               %{
                 idempotency_token: attempt.idempotency_token,
                 sequence: 3,
                 status: :failed,
                 reason: :command_failed
               },
               context
             )

    {pipeline, attempt}
  end
end
