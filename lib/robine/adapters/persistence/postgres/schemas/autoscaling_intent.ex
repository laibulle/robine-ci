defmodule Robine.Adapters.Persistence.Postgres.Schemas.AutoscalingIntent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "autoscaling_intents" do
    field :policy_id, :binary_id
    field :idempotency_key, :string
    field :action, Ecto.Enum, values: [:provision, :terminate]
    field :target_instance_id, :string
    field :status, Ecto.Enum, values: [:pending, :completed, :failed]
    field :desired_capacity, :integer
    field :observed_capacity, :integer
    field :last_error, :string
    field :attempted_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :policy_id,
      :idempotency_key,
      :action,
      :target_instance_id,
      :status,
      :desired_capacity,
      :observed_capacity,
      :last_error,
      :attempted_at,
      :completed_at
    ])
    |> validate_required([
      :id,
      :policy_id,
      :idempotency_key,
      :action,
      :status,
      :desired_capacity,
      :observed_capacity
    ])
    |> unique_constraint(:idempotency_key)
  end
end
