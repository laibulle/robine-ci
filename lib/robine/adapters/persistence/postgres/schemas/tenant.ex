defmodule Robine.Adapters.Persistence.Postgres.Schemas.Tenant do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "ci_tenants" do
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
