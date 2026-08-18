defmodule Robine.Repo.Migrations.AddRustDurableDelivery do
  use Ecto.Migration

  def change do
    alter table(:outbox_events) do
      add :delivery_attempts, :integer, null: false, default: 0
      add :available_at, :utc_datetime_usec, default: fragment("timezone('UTC', now())")
      add :last_error, :string
      add :dead_lettered_at, :utc_datetime_usec
    end

    execute(
      "UPDATE outbox_events SET available_at = occurred_at WHERE available_at IS NULL",
      "SELECT 1"
    )

    create index(:outbox_events, [:available_at, :occurred_at],
             where: "delivered_at IS NULL AND dead_lettered_at IS NULL"
           )

    create table(:durable_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, :string, null: false
      add :source_event_id, :binary_id, null: false
      add :kind, :string, null: false
      add :payload, :map, null: false
      add :status, :string, null: false, default: "available"
      add :attempts, :integer, null: false, default: 0
      add :available_at, :utc_datetime_usec, null: false
      add :claimed_at, :utc_datetime_usec
      add :claim_token, :binary_id
      add :last_error, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:durable_jobs, [:tenant_id, :source_event_id, :kind])

    create index(:durable_jobs, [:tenant_id, :status, :available_at],
             where: "status IN ('available', 'retry')"
           )

    create constraint(:durable_jobs, :durable_jobs_status,
             check: "status IN ('available', 'executing', 'retry', 'completed', 'discarded')"
           )

    create constraint(:durable_jobs, :durable_jobs_non_negative_attempts, check: "attempts >= 0")

    execute(
      "ALTER TABLE durable_jobs ALTER COLUMN tenant_id SET DEFAULT " <>
        "COALESCE(NULLIF(current_setting('robine.tenant_id', true), ''), 'standalone')",
      "ALTER TABLE durable_jobs ALTER COLUMN tenant_id DROP DEFAULT"
    )

    execute("ALTER TABLE durable_jobs ENABLE ROW LEVEL SECURITY", "SELECT 1")
    execute("ALTER TABLE durable_jobs FORCE ROW LEVEL SECURITY", "SELECT 1")

    execute(
      "CREATE POLICY durable_jobs_tenant_isolation ON durable_jobs " <>
        "USING (tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id', true), ''), " <>
        "'standalone')) WITH CHECK (tenant_id = COALESCE(NULLIF(current_setting(" <>
        "'robine.tenant_id', true), ''), 'standalone'))",
      "DROP POLICY IF EXISTS durable_jobs_tenant_isolation ON durable_jobs"
    )
  end
end
