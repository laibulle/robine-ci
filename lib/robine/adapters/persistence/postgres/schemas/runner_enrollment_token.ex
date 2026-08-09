defmodule Robine.Adapters.Persistence.Postgres.Schemas.RunnerEnrollmentToken do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "runner_enrollment_tokens" do
    field :token_digest, :binary
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :created_by, :string
    field :runner_id, :binary_id
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :token_digest,
      :expires_at,
      :consumed_at,
      :created_by,
      :runner_id,
      :inserted_at
    ])
    |> validate_required([:id, :token_digest, :expires_at, :created_by])
    |> unique_constraint(:token_digest)
  end
end
