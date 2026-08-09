defmodule Robine.Adapters.Persistence.Postgres.Schemas.StorageGcCandidate do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:blob_id, :string, autogenerate: false}
  schema "storage_gc_candidates" do
    field :not_before, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
