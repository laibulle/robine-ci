defmodule Robine.Adapters.Persistence.Postgres.Schemas.RunnerCredential do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "runner_credentials" do
    field :runner_id, :binary_id
    field :credential_digest, :binary
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :runner_id,
      :credential_digest,
      :expires_at,
      :revoked_at,
      :inserted_at
    ])
    |> validate_required([:id, :runner_id, :credential_digest])
    |> unique_constraint(:credential_digest)
  end
end
