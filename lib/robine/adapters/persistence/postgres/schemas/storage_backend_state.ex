defmodule Robine.Adapters.Persistence.Postgres.Schemas.StorageBackendState do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "storage_backend_states" do
    field :backend, :string
    field :namespace_digest, :string
    field :acknowledged_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(state, attributes) do
    state
    |> cast(attributes, [:id, :backend, :namespace_digest, :acknowledged_at])
    |> validate_required([:id, :backend, :namespace_digest])
  end
end
