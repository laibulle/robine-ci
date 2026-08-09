defmodule Robine.Repo.Migrations.CreateGitHubChecks do
  use Ecto.Migration

  def change do
    create table(:github_checks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :external_key, :string, null: false
      add :repository_id, :binary_id, null: false
      add :pipeline_id, :binary_id, null: false
      add :job_id, :binary_id
      add :provider_check_id, :bigint, null: false
      add :status, :string, null: false
      add :conclusion, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:github_checks, [:external_key])
    create index(:github_checks, [:pipeline_id])
  end
end
