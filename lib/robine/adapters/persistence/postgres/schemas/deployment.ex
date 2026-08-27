defmodule Robine.Adapters.Persistence.Postgres.Schemas.Deployment do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [
    :requested,
    :awaiting_approval,
    :queued,
    :preparing,
    :converging_services,
    :migrating,
    :activating,
    :verifying,
    :succeeded,
    :failed,
    :cancelled,
    :verification_failed
  ]

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "deployments" do
    field :environment_id, :binary_id
    field :repository_id, :binary_id
    field :requester_id, :string
    field :approver_id, :string
    field :attempt_id, :binary_id
    field :idempotency_token, :binary_id
    field :runner_id, :binary_id
    field :kind, Ecto.Enum, values: [:application, :platform, :rollback]
    field :status, Ecto.Enum, values: @statuses
    field :artifact, :map
    field :desired_state_digest, :string
    field :environment_snapshot, :map

    field :migration_policy, Ecto.Enum, values: [:application_only, :forward_only, :rollback_safe]

    field :event_sequence, :integer, default: 0
    field :failure_reason, :string
    field :requested_at, :utc_datetime_usec
    field :approved_at, :utc_datetime_usec
    field :assigned_at, :utc_datetime_usec
    field :lease_expires_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :environment_id,
      :repository_id,
      :requester_id,
      :approver_id,
      :attempt_id,
      :idempotency_token,
      :runner_id,
      :kind,
      :status,
      :artifact,
      :desired_state_digest,
      :environment_snapshot,
      :migration_policy,
      :event_sequence,
      :failure_reason,
      :requested_at,
      :approved_at,
      :assigned_at,
      :lease_expires_at,
      :started_at,
      :finished_at,
      :inserted_at,
      :updated_at
    ])
    |> validate_required([
      :id,
      :environment_id,
      :repository_id,
      :requester_id,
      :kind,
      :status,
      :artifact,
      :desired_state_digest,
      :environment_snapshot,
      :migration_policy,
      :event_sequence,
      :requested_at
    ])
    |> foreign_key_constraint(:environment_id)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:runner_id)
    |> unique_constraint(:environment_id,
      name: :deployments_one_active_per_environment_index
    )
    |> unique_constraint(:runner_id, name: :deployments_one_active_per_runner_index)
  end
end
