defmodule Robine.Adapters.Persistence.Postgres.Schemas.OutboxEvent do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "outbox_events" do
    field :event_type, :string
    field :aggregate_id, :binary_id
    field :payload, :map
    field :occurred_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [:id, :event_type, :aggregate_id, :payload, :occurred_at])
    |> validate_required([:id, :event_type, :aggregate_id, :payload, :occurred_at])
    |> unique_constraint(:id)
  end
end
