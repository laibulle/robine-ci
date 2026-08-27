defmodule Robine.Adapters.Persistence.Postgres.Schemas.PublicationPolicy do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "publication_policies" do
    field :repository_id, :binary_id
    field :enabled, :boolean, default: false
    field :public_slug, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [:id, :repository_id, :enabled, :public_slug, :inserted_at, :updated_at])
    |> validate_required([:id, :repository_id, :enabled, :public_slug])
    |> unique_constraint(:repository_id)
    |> unique_constraint(:public_slug)
    |> foreign_key_constraint(:repository_id)
  end
end
