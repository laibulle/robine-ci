defmodule Robine.Adapters.Persistence.Postgres.Schemas.Artifact do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: false}

  schema "artifacts" do
    field :repository_id, :binary_id
    field :attempt_id, :binary_id
    field :name, :string
    field :blob_id, :string
    field :digest, :string
    field :size, :integer
    field :created_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :repository_id,
      :attempt_id,
      :name,
      :blob_id,
      :digest,
      :size,
      :created_at,
      :expires_at
    ])
    |> validate_required([
      :id,
      :repository_id,
      :attempt_id,
      :name,
      :blob_id,
      :digest,
      :size,
      :created_at,
      :expires_at
    ])
    |> unique_constraint([:attempt_id, :name])
  end
end
