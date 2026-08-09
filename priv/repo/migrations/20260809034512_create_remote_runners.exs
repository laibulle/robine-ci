defmodule Robine.Repo.Migrations.CreateRemoteRunners do
  use Ecto.Migration

  def change do
    create table(:remote_runners, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :admin_state, :string, null: false, default: "enabled"
      add :protocol_version, :integer
      add :software_version, :string
      add :capabilities, :map, null: false, default: %{}
      add :last_authenticated_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:remote_runners, :remote_runners_admin_state,
             check: "admin_state IN ('enabled', 'draining', 'revoked')"
           )

    create table(:runner_enrollment_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_digest, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      add :created_by, :string, null: false
      add :runner_id, references(:remote_runners, type: :binary_id, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:runner_enrollment_tokens, [:token_digest])
    create index(:runner_enrollment_tokens, [:expires_at], where: "consumed_at IS NULL")

    create table(:runner_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :runner_id, references(:remote_runners, type: :binary_id, on_delete: :delete_all),
        null: false

      add :credential_digest, :binary, null: false
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:runner_credentials, [:credential_digest])
    create index(:runner_credentials, [:runner_id], where: "revoked_at IS NULL")
  end
end
