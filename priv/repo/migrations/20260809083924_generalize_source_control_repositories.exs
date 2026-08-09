defmodule Robine.Repo.Migrations.GeneralizeSourceControlRepositories do
  use Ecto.Migration

  def up do
    alter table(:github_repositories) do
      add :provider, :string, null: false, default: "github"
      add :provider_instance, :string, null: false, default: "default"
    end

    drop unique_index(:github_repositories, [:provider_id])
    drop unique_index(:github_repositories, [:full_name])

    create unique_index(
             :github_repositories,
             [:provider, :provider_instance, :provider_id],
             name: :source_control_repositories_provider_identity_index
           )

    create unique_index(
             :github_repositories,
             [:provider, :provider_instance, :full_name],
             name: :source_control_repositories_provider_name_index
           )
  end

  def down do
    drop index(:github_repositories, [:provider, :provider_instance, :provider_id],
           name: :source_control_repositories_provider_identity_index
         )

    drop index(:github_repositories, [:provider, :provider_instance, :full_name],
           name: :source_control_repositories_provider_name_index
         )

    create unique_index(:github_repositories, [:provider_id])
    create unique_index(:github_repositories, [:full_name])

    alter table(:github_repositories) do
      remove :provider
      remove :provider_instance
    end
  end
end
