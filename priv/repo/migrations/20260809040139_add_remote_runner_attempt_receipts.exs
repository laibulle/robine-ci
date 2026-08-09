defmodule Robine.Repo.Migrations.AddRemoteRunnerAttemptReceipts do
  use Ecto.Migration

  def change do
    alter table(:job_attempts) do
      add :runner_id, :string
    end

    create index(:job_attempts, [:runner_id], where: "runner_id IS NOT NULL")

    create table(:runner_attempt_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :runner_id, :string, null: false
      add :message_id, :string, null: false

      add :attempt_id, references(:job_attempts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sequence, :integer, null: false
      add :status, :string, null: false
      add :reason, :string
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:runner_attempt_events, [:runner_id, :message_id])
    create unique_index(:runner_attempt_events, [:attempt_id, :sequence])

    create constraint(:runner_attempt_events, :runner_attempt_events_positive_sequence,
             check: "sequence > 0"
           )
  end
end
