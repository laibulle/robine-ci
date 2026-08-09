defmodule Robine.Adapters.Persistence.Postgres.Schemas.LocalCredential do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: false}

  schema "local_credentials" do
    field :user_id, :binary_id
    field :password_hash, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [:id, :user_id, :password_hash, :inserted_at])
    |> validate_required([:id, :user_id, :password_hash])
    |> unique_constraint(:user_id)
  end
end
