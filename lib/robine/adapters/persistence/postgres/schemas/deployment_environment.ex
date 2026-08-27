defmodule Robine.Adapters.Persistence.Postgres.Schemas.DeploymentEnvironment do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "deployment_environments" do
    field :repository_id, :binary_id
    field :name, :string
    field :protection, Ecto.Enum, values: [:unprotected, :protected]
    field :runner_labels, {:array, :string}, default: []
    field :deployment_root, :string
    field :network_name, :string
    field :timeout_ms, :integer

    field :migration_policy, Ecto.Enum, values: [:application_only, :forward_only, :rollback_safe]

    field :verification, :map
    field :services, {:array, :map}
    field :desired_state_digest, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :repository_id,
      :name,
      :protection,
      :runner_labels,
      :deployment_root,
      :network_name,
      :timeout_ms,
      :migration_policy,
      :verification,
      :services,
      :desired_state_digest,
      :inserted_at,
      :updated_at
    ])
    |> validate_required([
      :id,
      :repository_id,
      :name,
      :protection,
      :runner_labels,
      :deployment_root,
      :network_name,
      :timeout_ms,
      :migration_policy,
      :verification,
      :services,
      :desired_state_digest
    ])
    |> unique_constraint([:repository_id, :name])
    |> unique_constraint(:network_name)
    |> foreign_key_constraint(:repository_id)
  end
end
