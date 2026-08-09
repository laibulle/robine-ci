defmodule Robine.Pipelines.UseCases.CreatePipelineTest do
  use ExUnit.Case, async: true

  alias Robine.ExecutionContext
  alias Robine.Pipelines
  alias Robine.Pipelines.Dependencies

  defmodule FakeUnitOfWork do
    @behaviour Robine.Pipelines.Ports.UnitOfWork
    @impl true
    def transaction(operation), do: operation.()
    @impl true
    def lock(_identity), do: :ok
  end

  defmodule FakePipelineRepository do
    @behaviour Robine.Pipelines.Ports.PipelineRepository
    @impl true
    def insert(pipeline) do
      send(self(), {:pipeline_inserted, pipeline})
      :ok
    end

    @impl true
    def insert_revision(revision) do
      send(self(), {:revision_inserted, revision})
      :ok
    end

    @impl true
    def get_revision(_pipeline_id), do: {:error, :not_found}

    @impl true
    def get(_id), do: {:error, :not_found}

    @impl true
    def update(_pipeline), do: :ok

    @impl true
    def list_recent(_limit), do: {:ok, []}
  end

  defmodule FakeEventOutbox do
    @behaviour Robine.Pipelines.Ports.EventOutbox
    @impl true
    def append(event) do
      send(self(), {:event_appended, event})
      :ok
    end

    @impl true
    def get(_id), do: {:error, :not_found}

    @impl true
    def mark_delivered(_id, _at), do: :ok
    @impl true
    def reconcile_pending(_limit), do: {:ok, 0}
  end

  defmodule FakeClock do
    @behaviour Robine.Pipelines.Ports.Clock
    @impl true
    def now, do: ~U[2026-08-08 12:00:00.123456Z]
  end

  defmodule FakeIdGenerator do
    @behaviour Robine.Pipelines.Ports.IdGenerator
    @impl true
    def generate, do: "9ce783f1-3cf2-4658-9647-1cab33e50745"
  end

  setup do
    dependencies = %Dependencies{
      unit_of_work: FakeUnitOfWork,
      pipeline_repository: FakePipelineRepository,
      event_outbox: FakeEventOutbox,
      clock: FakeClock,
      id_generator: FakeIdGenerator
    }

    %{dependencies: dependencies}
  end

  test "the facade delegates creation and appends a domain event", %{dependencies: dependencies} do
    context =
      ExecutionContext.new(%{id: "developer", role: :maintainer}, "correlation", %{
        pipelines: dependencies
      })

    input = %{
      repository_id: "17c78df0-bb10-46d6-9176-004cf068c56c",
      workflow_name: "CI",
      commit_sha: String.duplicate("a", 40)
    }

    assert {:ok, view} = Pipelines.create_pipeline(input, context)
    assert view.status == :created
    assert_receive {:pipeline_inserted, %{id: id}}
    assert_receive {:revision_inserted, %{pipeline_id: ^id, digest: digest}}
    assert byte_size(digest) == 64
    assert_receive {:event_appended, %{pipeline_id: ^id}}
  end

  test "viewers cannot create pipelines", %{dependencies: dependencies} do
    context =
      ExecutionContext.new(%{id: "developer", role: :viewer}, "correlation", %{
        pipelines: dependencies
      })

    assert {:error, :forbidden} = Pipelines.create_pipeline(%{}, context)
    refute_received {:pipeline_inserted, _pipeline}
  end
end
