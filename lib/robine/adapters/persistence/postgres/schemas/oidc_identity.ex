defmodule Robine.Adapters.Persistence.Postgres.Schemas.OIDCIdentity do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}

  schema "oidc_identities" do
    field :user_id, :binary_id
    field :issuer, :string
    field :subject, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [:user_id, :issuer, :subject, :inserted_at])
    |> validate_required([:user_id, :issuer, :subject])
    |> unique_constraint([:issuer, :subject])
  end
end
