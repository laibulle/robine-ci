defmodule Robine.Repo.Migrations.CreateDeploymentEnvironmentsAndDeployments do
  use Ecto.Migration

  @tenant_expression "COALESCE(NULLIF(current_setting('robine.tenant_id', true), ''), 'standalone')"

  def change do
    create table(:deployment_environments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id,
          references(:github_repositories, type: :binary_id, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :protection, :string, null: false
      add :runner_labels, {:array, :string}, null: false, default: []
      add :deployment_root, :string, null: false
      add :network_name, :string, null: false
      add :timeout_ms, :bigint, null: false
      add :migration_policy, :string, null: false
      add :verification, :map, null: false
      add :services, {:array, :map}, null: false
      add :desired_state_digest, :string, null: false
      add :tenant_id, :text, null: false, default: "standalone"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:deployment_environments, [:tenant_id, :repository_id, :name])
    create unique_index(:deployment_environments, [:tenant_id, :network_name])

    create table(:deployments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :environment_id,
          references(:deployment_environments, type: :binary_id, on_delete: :restrict), null: false

      add :repository_id,
          references(:github_repositories, type: :binary_id, on_delete: :delete_all), null: false

      add :requester_id, :string, null: false
      add :approver_id, :string
      add :kind, :string, null: false
      add :status, :string, null: false
      add :artifact, :map, null: false
      add :desired_state_digest, :string, null: false
      add :environment_snapshot, :map, null: false
      add :migration_policy, :string, null: false
      add :event_sequence, :bigint, null: false, default: 0
      add :failure_reason, :string
      add :requested_at, :utc_datetime_usec, null: false
      add :approved_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :tenant_id, :text, null: false, default: "standalone"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:deployments, [:tenant_id, :repository_id, :requested_at])
    create index(:deployments, [:tenant_id, :environment_id, :requested_at])

    create unique_index(:deployments, [:tenant_id, :environment_id],
             where:
               "status IN ('requested', 'awaiting_approval', 'queued', 'preparing', 'converging_services', 'migrating', 'activating', 'verifying')",
             name: :deployments_one_active_per_environment_index
           )

    create table(:deployment_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :deployment_id, references(:deployments, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sequence, :bigint, null: false
      add :from_status, :string, null: false
      add :to_status, :string, null: false
      add :reason, :string
      add :runner_id, references(:remote_runners, type: :binary_id, on_delete: :nilify_all)
      add :occurred_at, :utc_datetime_usec, null: false
      add :tenant_id, :text, null: false, default: "standalone"
    end

    create unique_index(:deployment_events, [:tenant_id, :deployment_id, :sequence])

    for table <- ~w(deployment_environments deployments deployment_events) do
      execute(
        "ALTER TABLE #{table} ALTER COLUMN tenant_id SET DEFAULT #{@tenant_expression}",
        "ALTER TABLE #{table} ALTER COLUMN tenant_id SET DEFAULT 'standalone'"
      )

      execute("ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY", "")
      execute("ALTER TABLE #{table} FORCE ROW LEVEL SECURITY", "")

      execute(
        "CREATE POLICY #{table}_tenant_isolation ON #{table} " <>
          "USING (tenant_id = #{@tenant_expression}) " <>
          "WITH CHECK (tenant_id = #{@tenant_expression})",
        "DROP POLICY IF EXISTS #{table}_tenant_isolation ON #{table}"
      )
    end

  end
end
