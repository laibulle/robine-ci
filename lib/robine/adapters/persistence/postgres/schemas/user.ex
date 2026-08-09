defmodule Robine.Adapters.Persistence.Postgres.Schemas.User do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: false}

  schema "users" do
    field :email, :string
    field :role, Ecto.Enum, values: [:administrator, :maintainer, :viewer]
    field :disabled, :boolean, default: false
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [:id, :email, :role, :disabled, :inserted_at])
    |> validate_required([:id, :email, :role, :disabled])
    |> unique_constraint(:email)
  end
end
