defmodule Robine.Repo.Migrations.AddNativeDeploymentDispatch do
  use Ecto.Migration

  def change do
    alter table(:deployments) do
      add :attempt_id, :binary_id
      add :idempotency_token, :binary_id
      add :runner_id, references(:remote_runners, type: :binary_id, on_delete: :nilify_all)
      add :assigned_at, :utc_datetime_usec
      add :lease_expires_at, :utc_datetime_usec
    end

    create unique_index(:deployments, [:attempt_id])
    create unique_index(:deployments, [:idempotency_token])

    create unique_index(:deployments, [:tenant_id, :runner_id],
             where:
               "runner_id IS NOT NULL AND status IN ('queued', 'preparing', 'converging_services', 'migrating', 'activating', 'verifying')",
             name: :deployments_one_active_per_runner_index
           )
  end
end
