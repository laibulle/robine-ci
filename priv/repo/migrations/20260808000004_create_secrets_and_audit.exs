defmodule Robine.Repo.Migrations.CreateSecretsAndAudit do
  use Ecto.Migration

  def change do
    create table(:secrets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :scope, :string, null: false
      add :repository_id, :binary_id
      add :allowed_repository_ids, {:array, :binary_id}, null: false, default: []
      add :ciphertext, :binary, null: false
      add :nonce, :binary, null: false
      add :tag, :binary, null: false
      add :key_version, :integer, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:secrets, [:scope, :repository_id, :name],
             nulls_distinct: false,
             name: :secrets_scope_repository_name_index
           )

    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :actor_id, :string, null: false
      add :action, :string, null: false
      add :target_type, :string, null: false
      add :target_id, :binary_id, null: false
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false
    end

    create index(:audit_events, [:target_type, :target_id, :occurred_at])
  end
end
