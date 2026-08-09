defmodule Robine.Adapters.Persistence.Postgres.Schemas.RunnerAttemptEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "runner_attempt_events" do
    field :runner_id, :string
    field :message_id, :string
    field :attempt_id, :binary_id
    field :sequence, :integer
    field :status, Ecto.Enum, values: Robine.Pipelines.Domain.Attempt.statuses()
    field :reason, Ecto.Enum, values: Robine.Pipelines.Domain.Attempt.reasons()
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :runner_id,
      :message_id,
      :attempt_id,
      :sequence,
      :status,
      :reason,
      :inserted_at
    ])
    |> validate_required([:id, :runner_id, :message_id, :attempt_id, :sequence, :status])
    |> validate_length(:runner_id, min: 1, max: 128)
    |> validate_length(:message_id, min: 1, max: 128)
    |> validate_number(:sequence, greater_than: 0)
    |> unique_constraint([:runner_id, :message_id])
    |> unique_constraint([:attempt_id, :sequence])
  end
end
