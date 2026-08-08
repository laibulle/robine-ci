defmodule Robine.Adapters.Persistence.Postgres.Schemas.Attempt do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "job_attempts" do
    field :job_id, :binary_id
    field :number, :integer
    field :idempotency_token, :binary_id
    field :status, Ecto.Enum, values: Robine.Pipelines.Domain.Attempt.statuses()
    field :lease_expires_at, :utc_datetime_usec
    field :last_sequence, :integer, default: 0
    field :result_reason, Ecto.Enum, values: Robine.Pipelines.Domain.Attempt.reasons()
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :job_id,
      :number,
      :idempotency_token,
      :status,
      :lease_expires_at,
      :last_sequence,
      :result_reason
    ])
    |> validate_required([
      :id,
      :job_id,
      :number,
      :idempotency_token,
      :status,
      :lease_expires_at,
      :last_sequence
    ])
    |> unique_constraint([:job_id, :number])
    |> unique_constraint(:idempotency_token)
  end
end
