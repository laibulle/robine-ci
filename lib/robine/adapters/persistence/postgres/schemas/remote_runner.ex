defmodule Robine.Adapters.Persistence.Postgres.Schemas.RemoteRunner do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "remote_runners" do
    field :name, :string
    field :admin_state, Ecto.Enum, values: [:enabled, :draining, :revoked]
    field :protocol_version, :integer
    field :software_version, :string
    field :capabilities, :map, default: %{}
    field :labels, {:array, :string}, default: []
    field :last_authenticated_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :name,
      :admin_state,
      :protocol_version,
      :software_version,
      :capabilities,
      :labels,
      :last_authenticated_at,
      :last_seen_at,
      :revoked_at,
      :inserted_at,
      :updated_at
    ])
    |> validate_required([:id, :name, :admin_state, :capabilities])
    |> validate_length(:name, min: 1, max: 80)
  end
end
