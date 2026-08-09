defmodule Robine.Adapters.Persistence.Postgres.Schemas.WorkflowRevision do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "workflow_revisions" do
    field :pipeline_id, :binary_id
    field :path, :string
    field :source, :string
    field :digest, :string
    field :normalized_graph, :map
    field :included_sources, :map, default: %{}
    field :created_at, :utc_datetime_usec
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :pipeline_id,
      :path,
      :source,
      :digest,
      :normalized_graph,
      :included_sources,
      :created_at
    ])
    |> validate_required([
      :id,
      :pipeline_id,
      :path,
      :source,
      :digest,
      :normalized_graph,
      :included_sources,
      :created_at
    ])
    |> unique_constraint(:id, name: :workflow_revisions_pkey)
    |> unique_constraint(:pipeline_id, name: :workflow_revisions_pipeline_id_index)
  end
end
