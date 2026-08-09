defmodule Robine.Adapters.Persistence.Postgres.Schemas.CacheEntry do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: false}

  schema "cache_entries" do
    field :repository_id, :binary_id
    field :key, :string
    field :blob_id, :string
    field :digest, :string
    field :size, :integer
    field :created_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :last_restored_at, :utc_datetime_usec
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :repository_id,
      :key,
      :blob_id,
      :digest,
      :size,
      :created_at,
      :expires_at,
      :last_restored_at
    ])
    |> validate_required([
      :id,
      :repository_id,
      :key,
      :blob_id,
      :digest,
      :size,
      :created_at,
      :expires_at
    ])
    |> unique_constraint([:repository_id, :key])
  end
end
