defmodule Robine.Adapters.Persistence.Postgres.PipelineTransactionTest do
  use Robine.DataCase, async: true

  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    Job,
    OutboxEvent,
    Pipeline,
    WorkflowRevision
  }

  alias Robine.Pipelines
  alias Robine.Runtime.Dependencies
  alias Robine.Repo
  alias Robine.Workflows.Domain.{Service, Step}

  test "persists a pipeline and its outbox event atomically" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "test-correlation")

    input = %{
      repository_id: Ecto.UUID.generate(),
      workflow_name: "CI",
      commit_sha: String.duplicate("b", 40)
    }

    assert {:ok, view} = Pipelines.create_pipeline(input, context)
    assert %Pipeline{id: id, status: :created} = Repo.get!(Pipeline, view.id)

    assert %OutboxEvent{event_type: "pipeline.created", aggregate_id: ^id} =
             Repo.one!(from event in OutboxEvent, where: event.aggregate_id == ^id)

    assert %WorkflowRevision{pipeline_id: ^id, digest: digest, normalized_graph: %{"jobs" => %{}}} =
             Repo.one!(from revision in WorkflowRevision, where: revision.pipeline_id == ^id)

    assert byte_size(digest) == 64

    assert {:ok, revision} = Pipelines.workflow_revision(%{pipeline_id: id}, context)
    assert revision.digest == digest

    assert %Oban.Job{queue: "outbox", args: %{"event_id" => _event_id}} = Repo.one!(Oban.Job)
  end

  test "persists service secret references but never resolved service values" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "service-persistence")

    service = %Service{
      id: "postgres",
      image: "postgres:18-alpine",
      env: %{"POSTGRES_DB" => "app_test"},
      secret_env: %{"POSTGRES_PASSWORD" => "TEST_DB_PASSWORD"},
      readiness: %{tcp: 5432, timeout_ms: 45_000}
    }

    job = %Robine.Workflows.Domain.Job{
      id: "test",
      image: "alpine:3.22",
      needs: [],
      condition: :always,
      secrets: ["TEST_DB_PASSWORD"],
      services: %{"postgres" => service},
      steps: [%Step{name: "Test", kind: :run, value: "true", condition: :failure}]
    }

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Services",
                 commit_sha: String.duplicate("c", 40),
                 jobs: %{"test" => job}
               },
               context
             )

    persisted = Repo.one!(from job in Job, where: job.pipeline_id == ^pipeline.id)

    assert persisted.execution_spec["services"]["postgres"]["secret_env"] == %{
             "POSTGRES_PASSWORD" => "TEST_DB_PASSWORD"
           }

    assert persisted.execution_spec["condition"] == "always"
    assert hd(persisted.execution_spec["steps"])["condition"] == "failure"

    refute inspect(persisted.execution_spec) =~ "resolved-service-value"
  end

  test "persists immutable matrix identity and values in jobs and workflow revisions" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "matrix-persistence")

    job = %Robine.Workflows.Domain.Job{
      id: "test[otp=27]",
      base_id: "test",
      matrix_values: %{"otp" => "27"},
      image: "elixir:1.18-otp-27",
      env: %{"ROBINE_MATRIX_OTP" => "27"},
      needs: [],
      steps: [%Step{name: "Test", kind: :run, value: "true"}]
    }

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Matrix",
                 commit_sha: String.duplicate("d", 40),
                 jobs: %{job.id => job}
               },
               context
             )

    persisted = Repo.one!(from stored in Job, where: stored.pipeline_id == ^pipeline.id)
    assert persisted.job_key == "test[otp=27]"
    assert persisted.execution_spec["base_id"] == "test"
    assert persisted.execution_spec["matrix_values"] == %{"otp" => "27"}
    assert persisted.execution_spec["env"]["ROBINE_MATRIX_OTP"] == "27"

    revision =
      Repo.one!(from stored in WorkflowRevision, where: stored.pipeline_id == ^pipeline.id)

    graph_job = revision.normalized_graph["jobs"]["test[otp=27]"]
    assert graph_job["base_id"] == "test"
    assert graph_job["matrix_values"] == %{"otp" => "27"}
  end

  test "duplicate matrix pipeline creation reuses one durable variant set" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "matrix-idempotency")

    jobs =
      for version <- ["3.21", "3.22"], into: %{} do
        key = "test[version=#{version}]"

        {key,
         %Robine.Workflows.Domain.Job{
           id: key,
           base_id: "test",
           matrix_values: %{"version" => version},
           image: "alpine:#{version}",
           env: %{"ROBINE_MATRIX_VERSION" => version},
           needs: [],
           steps: [%Step{name: "Test", kind: :run, value: "true"}]
         }}
      end

    input = %{
      repository_id: Ecto.UUID.generate(),
      workflow_name: "Idempotent matrix",
      commit_sha: String.duplicate("a", 40),
      idempotency_key: "matrix-delivery",
      jobs: jobs
    }

    assert {:ok, first} = Pipelines.create_pipeline(input, context)
    assert {:ok, second} = Pipelines.create_pipeline(input, context)
    assert second.id == first.id
    assert Repo.aggregate(from(job in Job, where: job.pipeline_id == ^first.id), :count) == 2
  end
end
