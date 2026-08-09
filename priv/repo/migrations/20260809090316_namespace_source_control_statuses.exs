defmodule Robine.Repo.Migrations.NamespaceSourceControlStatuses do
  use Ecto.Migration

  def up do
    alter table(:github_checks) do
      add :provider, :string, null: false, default: "github"
      add :provider_instance, :string, null: false, default: "default"
    end

    drop unique_index(:github_checks, [:external_key])

    create unique_index(
             :github_checks,
             [:provider, :provider_instance, :external_key],
             name: :source_control_statuses_provider_external_key_index
           )
  end

  def down do
    drop index(:github_checks, [:provider, :provider_instance, :external_key],
           name: :source_control_statuses_provider_external_key_index
         )

    create unique_index(:github_checks, [:external_key])

    alter table(:github_checks) do
      remove :provider
      remove :provider_instance
    end
  end
end
