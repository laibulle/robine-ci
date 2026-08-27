defmodule Robine.Repo.Migrations.SerializeActiveDeploymentsPerEnvironment do
  use Ecto.Migration

  def up do
    drop_if_exists index(:deployments, [:tenant_id, :environment_id],
                     name: :deployments_one_active_per_environment_index
                   )

    create unique_index(:deployments, [:tenant_id, :environment_id],
             where:
               "(runner_id IS NOT NULL OR status IN ('preparing', 'converging_services', 'migrating', 'activating', 'verifying'))",
             name: :deployments_one_active_per_environment_index
           )
  end

  def down do
    drop_if_exists index(:deployments, [:tenant_id, :environment_id],
                     name: :deployments_one_active_per_environment_index
                   )

    create unique_index(:deployments, [:tenant_id, :environment_id],
             where:
               "status IN ('requested', 'awaiting_approval', 'queued', 'preparing', 'converging_services', 'migrating', 'activating', 'verifying')",
             name: :deployments_one_active_per_environment_index
           )
  end
end
