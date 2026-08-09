defmodule Robine.Repo.Migrations.AddHealthToScheduleReconciliationState do
  use Ecto.Migration

  def change do
    alter table(:schedule_reconciliation_states) do
      modify :cursor, :utc_datetime_usec, null: true, from: {:utc_datetime_usec, null: false}
      add :last_attempt_at, :utc_datetime_usec
      add :last_success_at, :utc_datetime_usec
      add :last_failure, :string
    end
  end
end
