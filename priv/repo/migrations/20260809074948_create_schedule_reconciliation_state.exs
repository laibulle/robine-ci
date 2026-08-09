defmodule Robine.Repo.Migrations.CreateScheduleReconciliationState do
  use Ecto.Migration

  def change do
    create table(:schedule_reconciliation_states, primary_key: false) do
      add :key, :string, primary_key: true
      add :cursor, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
