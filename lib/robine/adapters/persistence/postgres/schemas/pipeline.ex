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
    field :status, Ecto.Enum, values: Robine.Pipelines.Domain.Pipeline.statuses()
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [:id, :repository_id, :workflow_name, :commit_sha, :status, :inserted_at])
    |> validate_required([
      :id,
      :repository_id,
      :workflow_name,
      :commit_sha,
      :status,
      :inserted_at
    ])
    |> unique_constraint(:id)
  end
end
