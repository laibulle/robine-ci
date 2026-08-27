defmodule Robine.Repo.Migrations.AddDeploymentEventMessageIds do
  use Ecto.Migration

  def up do
    alter table(:deployment_events) do
      add :message_id, :binary_id
    end

    execute(
      "UPDATE deployment_events SET message_id = gen_random_uuid() WHERE message_id IS NULL"
    )

    alter table(:deployment_events) do
      modify :message_id, :binary_id, null: false
    end

    create unique_index(:deployment_events, [:tenant_id, :message_id])
  end

  def down do
    drop_if_exists index(:deployment_events, [:tenant_id, :message_id])

    alter table(:deployment_events) do
      remove :message_id
    end
  end
end
