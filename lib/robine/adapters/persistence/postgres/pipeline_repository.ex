defmodule Robine.Adapters.Persistence.Postgres.PipelineRepository do
  @moduledoc false
  @behaviour Robine.Pipelines.Ports.PipelineRepository

  alias Robine.Adapters.Persistence.Postgres.Schemas.Pipeline, as: PipelineSchema
  alias Robine.Pipelines.Domain.Pipeline
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
        schema
        |> PipelineSchema.changeset(Map.from_struct(pipeline))
        |> Repo.update()
        |> case do
          {:ok, _schema} -> :ok
          {:error, changeset} -> {:error, {:persistence, changeset}}
        end
    end
  end

  defp to_domain(schema) do
    struct!(Pipeline, %{
      id: schema.id,
      repository_id: schema.repository_id,
      workflow_name: schema.workflow_name,
      commit_sha: schema.commit_sha,
      status: schema.status,
      inserted_at: schema.inserted_at
    })
  end
end
