defmodule Robine.Repo.Migrations.CreateLogChunks do
  use Ecto.Migration

  def change do
    create table(:log_chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :attempt_id, references(:job_attempts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sequence, :bigint, null: false
      add :step_position, :integer, null: false
      add :step_name, :string, null: false
      add :step_status, :string, null: false
      add :exit_code, :integer
      add :duration_ms, :integer, null: false
      add :content, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:log_chunks, [:attempt_id, :sequence])
    create index(:log_chunks, [:attempt_id, :step_position, :sequence])
  end
end
