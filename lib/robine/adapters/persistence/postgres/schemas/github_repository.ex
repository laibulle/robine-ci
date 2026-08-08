defmodule Robine.Adapters.Persistence.Postgres.Schemas.GitHubRepository do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: false}

  schema "github_repositories" do
    field :provider_id, :integer
    field :installation_id, :integer
    field :owner, :string
    field :name, :string
    field :full_name, :string
    field :trusted, :boolean
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :provider_id,
      :installation_id,
      :owner,
      :name,
      :full_name,
      :trusted,
      :inserted_at
    ])
    |> validate_required([
      :id,
      :provider_id,
      :installation_id,
      :owner,
      :name,
      :full_name,
      :trusted,
      :inserted_at
    ])
    |> unique_constraint(:provider_id)
    |> unique_constraint(:full_name)
  end
end
