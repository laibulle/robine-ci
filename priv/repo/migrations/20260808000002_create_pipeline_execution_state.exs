defmodule Robine.Repo.Migrations.CreatePipelineExecutionState do
  use Ecto.Migration

  def change do
    create table(:pipeline_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :pipeline_id, references(:pipelines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :job_key, :string, null: false
      add :status, :string, null: false
      add :needs, {:array, :string}, null: false, default: []
      add :position, :integer, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pipeline_jobs, [:pipeline_id, :job_key])
    create index(:pipeline_jobs, [:status, :inserted_at])

    create table(:job_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :job_id, references(:pipeline_jobs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :number, :integer, null: false
      add :idempotency_token, :binary_id, null: false
      add :status, :string, null: false
      add :lease_expires_at, :utc_datetime_usec, null: false
      add :last_sequence, :integer, null: false, default: 0
      add :result_reason, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:job_attempts, [:job_id, :number])
    create unique_index(:job_attempts, [:idempotency_token])
    create index(:job_attempts, [:status, :lease_expires_at])

    create table(:attempt_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :attempt_id, references(:job_attempts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :position, :integer, null: false
      add :status, :string, null: false
      add :exit_code, :integer
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:attempt_steps, [:attempt_id, :position])
  end
end
