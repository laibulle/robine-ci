defmodule Robine.Repo.Migrations.CreateGitHubIntegration do
  use Ecto.Migration

  def change do
    create table(:github_repositories, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider_id, :bigint, null: false
      add :installation_id, :bigint, null: false
      add :owner, :string, null: false
      add :name, :string, null: false
      add :full_name, :string, null: false
      add :trusted, :boolean, null: false, default: true
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:github_repositories, [:provider_id])
    create unique_index(:github_repositories, [:full_name])

    create table(:github_deliveries, primary_key: false) do
      add :id, :string, primary_key: true
      add :event, :string, null: false
      add :payload, :map, null: false
      add :status, :string, null: false
      add :received_at, :utc_datetime_usec, null: false
      add :processed_at, :utc_datetime_usec
      add :failure, :text
    end

    create index(:github_deliveries, [:status, :received_at])
  end
end
