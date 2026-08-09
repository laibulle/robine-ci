defmodule Robine.Adapters.Persistence.Postgres.Schemas.ScheduleReconciliationState do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  schema "schedule_reconciliation_states" do
    field :cursor, :utc_datetime_usec
    field :last_attempt_at, :utc_datetime_usec
    field :last_success_at, :utc_datetime_usec
    field :last_failure, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :key,
      :cursor,
      :last_attempt_at,
      :last_success_at,
      :last_failure
    ])
    |> validate_required([:key])
  end
end
