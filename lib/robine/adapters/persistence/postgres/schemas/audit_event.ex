defmodule Robine.Adapters.Persistence.Postgres.Schemas.AuditEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "audit_events" do
    field :actor_id, :string
    field :action, :string
    field :target_type, :string
    field :target_id, :binary_id
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [:actor_id, :action, :target_type, :target_id, :metadata, :occurred_at])
    |> validate_required([:actor_id, :action, :target_type, :target_id, :occurred_at])
  end
end
