defmodule Robine.Repo.Migrations.CreateArtifactsAndCaches do
  use Ecto.Migration

  def change do
    create table(:artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :repository_id, :binary_id, null: false
      add :attempt_id, :binary_id, null: false
      add :name, :string, null: false
      add :blob_id, :string, null: false
      add :digest, :string, null: false
      add :size, :bigint, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    create unique_index(:artifacts, [:attempt_id, :name])
    create index(:artifacts, [:repository_id, :expires_at])

    create table(:cache_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :repository_id, :binary_id, null: false
      add :key, :string, size: 512, null: false
      add :blob_id, :string, null: false
      add :digest, :string, null: false
      add :size, :bigint, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :last_restored_at, :utc_datetime_usec
    end

    create unique_index(:cache_entries, [:repository_id, :key])
    create index(:cache_entries, [:expires_at, :last_restored_at])
  end
end
