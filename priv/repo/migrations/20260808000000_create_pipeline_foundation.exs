defmodule Robine.Repo.Migrations.CreatePipelineFoundation do
  use Ecto.Migration

  def change do
    create table(:pipelines, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :repository_id, :binary_id, null: false
      add :workflow_name, :string, null: false
      add :commit_sha, :string, size: 40, null: false
      add :status, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:pipelines, [:repository_id, :inserted_at])

    create table(:outbox_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_type, :string, null: false
      add :aggregate_id, :binary_id, null: false
      add :payload, :map, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :delivered_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:outbox_events, [:delivered_at, :inserted_at])
    create index(:outbox_events, [:aggregate_id])
  end
end
