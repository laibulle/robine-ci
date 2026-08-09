defmodule Robine.Adapters.Persistence.Postgres.PipelineTransactionTest do
  use Robine.DataCase, async: true

  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{OutboxEvent, Pipeline, WorkflowRevision}
  alias Robine.Pipelines
  alias Robine.Runtime.Dependencies
  alias Robine.Repo

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
end
