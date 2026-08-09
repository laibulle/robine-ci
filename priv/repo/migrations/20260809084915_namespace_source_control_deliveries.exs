defmodule Robine.Repo.Migrations.NamespaceSourceControlDeliveries do
  use Ecto.Migration

  def up do
    alter table(:github_deliveries) do
      add :provider, :string, null: false, default: "github"
      add :provider_instance, :string, null: false, default: "default"
      add :provider_delivery_id, :string
    end

    execute("UPDATE github_deliveries SET provider_delivery_id = id")

    alter table(:github_deliveries) do
      modify :provider_delivery_id, :string, null: false
    end

    create unique_index(
             :github_deliveries,
             [:provider, :provider_instance, :provider_delivery_id],
             name: :source_control_deliveries_provider_identity_index
           )
  end

  def down do
    drop index(:github_deliveries, [:provider, :provider_instance, :provider_delivery_id],
           name: :source_control_deliveries_provider_identity_index
         )

    alter table(:github_deliveries) do
      remove :provider
      remove :provider_instance
      remove :provider_delivery_id
    end
  end
end
