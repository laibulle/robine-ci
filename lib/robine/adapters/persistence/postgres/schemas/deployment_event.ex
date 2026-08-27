defmodule Robine.Adapters.Persistence.Postgres.Schemas.DeploymentEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "deployment_events" do
    field :deployment_id, :binary_id
    field :message_id, :binary_id
    field :sequence, :integer
    field :from_status, :string
    field :to_status, :string
    field :reason, :string
    field :runner_id, :binary_id
    field :occurred_at, :utc_datetime_usec
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :deployment_id,
      :message_id,
      :sequence,
      :from_status,
      :to_status,
      :reason,
      :runner_id,
      :occurred_at
    ])
    |> validate_required([
      :id,
      :deployment_id,
      :message_id,
      :sequence,
      :from_status,
      :to_status,
      :occurred_at
    ])
    |> unique_constraint([:tenant_id, :message_id])
    |> unique_constraint([:deployment_id, :sequence])
    |> foreign_key_constraint(:deployment_id)
    |> foreign_key_constraint(:runner_id)
  end
end
