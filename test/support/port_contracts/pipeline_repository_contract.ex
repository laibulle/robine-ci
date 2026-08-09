defmodule Robine.TestSupport.PortContracts.PipelineRepositoryContract do
  @moduledoc false

  defmacro __using__(adapter: adapter) do
    quote bind_quoted: [adapter: adapter] do
      alias Robine.Pipelines.Domain.{Pipeline, WorkflowRevision}

      @pipeline_repository_adapter adapter

      test "pipeline repository satisfies insert, get, update, list, and missing contracts" do
        pipeline = contract_pipeline()

        assert {:error, :not_found} = @pipeline_repository_adapter.get(pipeline.id)
        assert :ok = @pipeline_repository_adapter.insert(pipeline)
        assert {:ok, ^pipeline} = @pipeline_repository_adapter.get(pipeline.id)

        updated = %{pipeline | status: :queued}
        assert :ok = @pipeline_repository_adapter.update(updated)
        assert {:ok, ^updated} = @pipeline_repository_adapter.get(pipeline.id)
        assert {:ok, recent} = @pipeline_repository_adapter.list_recent(10)
        assert Enum.any?(recent, &(&1 == updated))

        assert {:error, {:persistence, _changeset}} =
                 @pipeline_repository_adapter.insert(pipeline)
      end

      test "pipeline repository preserves immutable workflow revisions" do
        pipeline = contract_pipeline()
        revision = contract_revision(pipeline.id)

        assert :ok = @pipeline_repository_adapter.insert(pipeline)
        assert {:error, :not_found} = @pipeline_repository_adapter.get_revision(pipeline.id)
        assert :ok = @pipeline_repository_adapter.insert_revision(revision)
        assert {:ok, ^revision} = @pipeline_repository_adapter.get_revision(pipeline.id)

        assert {:error, {:workflow_revision_persistence, _changeset}} =
                 @pipeline_repository_adapter.insert_revision(revision)
      end

      defp contract_pipeline do
        %Pipeline{
          id: Ecto.UUID.generate(),
          repository_id: Ecto.UUID.generate(),
          workflow_name: "Port contract",
          commit_sha: String.duplicate("c", 40),
          status: :created,
          inserted_at: ~U[2026-08-09 12:00:00.000000Z]
        }
      end

      defp contract_revision(pipeline_id) do
        source = "version: 1\n"

        %WorkflowRevision{
          id: Ecto.UUID.generate(),
          pipeline_id: pipeline_id,
          path: ".robine-ci/workflows/ci.yml",
          source: source,
          digest: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower),
          normalized_graph: %{"jobs" => %{}},
          created_at: ~U[2026-08-09 12:00:00.000000Z]
        }
      end
    end
  end
end
