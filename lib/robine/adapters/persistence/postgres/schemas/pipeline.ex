defmodule Robine.Adapters.Persistence.Postgres.Schemas.Pipeline do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "pipelines" do
    field :repository_id, :binary_id
    field :workflow_name, :string
    field :commit_sha, :string
    field :trigger, :string
    field :actor, :string
    field :status, Ecto.Enum, values: Robine.Pipelines.Domain.Pipeline.statuses()
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :repository_id,
      :workflow_name,
      :commit_sha,
      :trigger,
      :actor,
      :status,
      :inserted_at,
      :started_at,
      :finished_at
    ])
    |> validate_required([
      :id,
      :repository_id,
      :workflow_name,
      :commit_sha,
      :trigger,
      :actor,
      :status,
      :inserted_at
    ])
    |> unique_constraint(:id, name: :pipelines_pkey)
  end
end
