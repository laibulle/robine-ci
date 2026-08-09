defmodule Robine.Adapters.Persistence.Postgres.Schemas.Session do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: false}

  schema "sessions" do
    field :user_id, :binary_id
    field :token_digest, :binary
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [:id, :user_id, :token_digest, :expires_at, :revoked_at, :inserted_at])
    |> validate_required([:id, :user_id, :token_digest, :expires_at])
    |> unique_constraint(:token_digest)
  end
end
