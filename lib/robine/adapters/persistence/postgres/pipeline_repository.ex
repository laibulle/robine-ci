defmodule Robine.Adapters.Persistence.Postgres.PipelineRepository do
  @moduledoc false
  @behaviour Robine.Pipelines.Ports.PipelineRepository

  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.Pipeline, as: PipelineSchema
  alias Robine.Adapters.Persistence.Postgres.Schemas.WorkflowRevision, as: RevisionSchema
  alias Robine.Pipelines.Domain.{Pipeline, WorkflowRevision}
  alias Robine.Repo

  @impl true
  def insert(%Pipeline{} = pipeline) do
    pipeline
    |> Map.from_struct()
    |> then(&PipelineSchema.changeset(%PipelineSchema{}, &1))
    |> Repo.insert()
    |> case do
      {:ok, _schema} -> :ok
      {:error, changeset} -> {:error, {:persistence, changeset}}
    end
  end

  @impl true
  def get(id) when is_binary(id) do
    case Repo.get(PipelineSchema, id) do
      nil -> {:error, :not_found}
      schema -> {:ok, to_domain(schema)}
    end
  end

  @impl true
  def update(%Pipeline{} = pipeline) do
    case Repo.get(PipelineSchema, pipeline.id) do
      nil ->
        {:error, :not_found}

      schema ->
        result =
          schema
          |> PipelineSchema.changeset(Map.from_struct(pipeline))
          |> Repo.update()
          |> case do
            {:ok, _schema} -> :ok
            {:error, changeset} -> {:error, {:persistence, changeset}}
          end

        if schema.status != pipeline.status do
          :telemetry.execute(
            [:robine, :pipeline, :transition],
            %{count: 1},
            %{entity: :pipeline, outcome: if(result == :ok, do: :ok, else: :error)}
          )
        end

        if result == :ok and pipeline.status in [:succeeded, :failed, :cancelled] and
             not is_nil(pipeline.started_at) and not is_nil(pipeline.finished_at) do
          :telemetry.execute(
            [:robine, :pipeline, :duration],
            %{
              duration: DateTime.diff(pipeline.finished_at, pipeline.started_at, :millisecond)
            },
            %{outcome: pipeline.status}
          )
        end

        result
    end
  end

  @impl true
  def list_recent(limit) when is_integer(limit) and limit > 0 do
    pipelines =
      Repo.all(
        from pipeline in PipelineSchema, order_by: [desc: pipeline.inserted_at], limit: ^limit
      )

    {:ok, Enum.map(pipelines, &to_domain/1)}
  end

  @impl true
  def insert_revision(%WorkflowRevision{} = revision) do
    revision
    |> Map.from_struct()
    |> then(&RevisionSchema.changeset(%RevisionSchema{}, &1))
    |> Repo.insert()
    |> case do
      {:ok, _schema} -> :ok
      {:error, changeset} -> {:error, {:workflow_revision_persistence, changeset}}
    end
  end

  @impl true
  def get_revision(pipeline_id) when is_binary(pipeline_id) do
    case Repo.one(from revision in RevisionSchema, where: revision.pipeline_id == ^pipeline_id) do
      nil -> {:error, :not_found}
      schema -> {:ok, revision_to_domain(schema)}
    end
  end

  defp to_domain(schema) do
    struct!(Pipeline, %{
      id: schema.id,
      repository_id: schema.repository_id,
      workflow_name: schema.workflow_name,
      commit_sha: schema.commit_sha,
      trigger: schema.trigger,
      actor: schema.actor,
      correlation_id: schema.correlation_id,
      status: schema.status,
      inserted_at: schema.inserted_at,
      started_at: schema.started_at,
      finished_at: schema.finished_at,
      scheduled_for: schema.scheduled_for,
      inputs: schema.inputs || %{}
    })
  end

  defp revision_to_domain(schema) do
    struct!(WorkflowRevision, %{
      id: schema.id,
      pipeline_id: schema.pipeline_id,
      path: schema.path,
      source: schema.source,
      digest: schema.digest,
      normalized_graph: schema.normalized_graph,
      included_sources: schema.included_sources || %{},
      created_at: schema.created_at
    })
  end
end
