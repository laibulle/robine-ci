defmodule Robine.Repo.Migrations.CreateStorageGcCandidates do
  use Ecto.Migration

  def change do
    create table(:storage_gc_candidates, primary_key: false) do
      add :blob_id, :string, primary_key: true
      add :not_before, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:storage_gc_candidates, [:not_before])
    create index(:log_chunks, [:inserted_at])
  end
end
