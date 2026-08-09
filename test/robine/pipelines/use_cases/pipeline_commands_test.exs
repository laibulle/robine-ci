defmodule Robine.Pipelines.UseCases.PipelineCommandsTest do
  use ExUnit.Case, async: true

  alias Robine.ExecutionContext
  alias Robine.Pipelines
  alias Robine.Pipelines.Dependencies
  alias Robine.Pipelines.Domain.Pipeline

  defmodule FakeUnitOfWork do
    @behaviour Robine.Pipelines.Ports.UnitOfWork
    def transaction(operation), do: operation.()
  end

  defmodule FakeRepository do
    @behaviour Robine.Pipelines.Ports.PipelineRepository
    def insert(_pipeline), do: :ok
    def insert_revision(_revision), do: :ok
    def get_revision(_pipeline_id), do: {:error, :not_found}

    def get(id) do
      status = Process.get({__MODULE__, id}, :created)
      {:ok, pipeline(id, status)}
    end

    def update(pipeline) do
      Process.put({__MODULE__, pipeline.id}, pipeline.status)
      :ok
    end

    def list_recent(_limit), do: {:ok, []}

    defp pipeline(id, status) do
      %Pipeline{
        id: id,
        repository_id: "repository",
        workflow_name: "CI",
        commit_sha: String.duplicate("a", 40),
        trigger: "manual",
        actor: "developer",
        status: status,
        inserted_at: ~U[2026-08-08 12:00:00Z]
      }
    end
  end

  defmodule UnusedOutbox do
    @behaviour Robine.Pipelines.Ports.EventOutbox
    @impl true
    def append(_event), do: :ok
    @impl true
    def get(_id), do: {:error, :not_found}
    @impl true
    def mark_delivered(_id, _at), do: :ok
    @impl true
    def reconcile_pending(_limit), do: {:ok, 0}
  end

  defmodule Clock do
    @behaviour Robine.Pipelines.Ports.Clock
    def now, do: ~U[2026-08-08 12:00:00Z]
  end

  defmodule IdGenerator do
    @behaviour Robine.Pipelines.Ports.IdGenerator
    def generate, do: "id"
  end

  setup do
    context =
      ExecutionContext.new(%{id: "developer", role: :maintainer}, "correlation", %{
        pipelines: %Dependencies{
          unit_of_work: FakeUnitOfWork,
          pipeline_repository: FakeRepository,
          event_outbox: UnusedOutbox,
          clock: Clock,
          id_generator: IdGenerator
        }
      })

    %{context: context}
  end

  test "queues and cancels a pipeline through facade delegates", %{context: context} do
    assert {:ok, %{status: :queued}} =
             Pipelines.queue_pipeline(%{pipeline_id: "pipeline"}, context)

    Process.put({FakeRepository, "pipeline"}, :running)

    assert {:ok, %{status: :cancelling}} =
             Pipelines.cancel_pipeline(%{pipeline_id: "pipeline"}, context)
  end

  test "a viewer cannot issue lifecycle commands", %{context: context} do
    viewer = %{context | actor: %{id: "viewer", role: :viewer}}
    assert {:error, :forbidden} = Pipelines.queue_pipeline(%{pipeline_id: "pipeline"}, viewer)
  end
end
