defmodule Robine.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  @tenant_expression "COALESCE(NULLIF(current_setting('robine.tenant_id', true), ''), 'standalone')"

  def change do
    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :repository_id,
          references(:github_repositories, type: :binary_id, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :token_prefix, :string, null: false
      add :token_digest, :binary, null: false
      add :permissions, {:array, :string}, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :tenant_id, :text, null: false, default: "standalone"
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:api_tokens, [:tenant_id, :token_digest])
    create index(:api_tokens, [:tenant_id, :repository_id, :inserted_at])
    create index(:api_tokens, [:tenant_id, :user_id])

    create constraint(:api_tokens, :api_tokens_artifact_upload_permission,
             check: "permissions = ARRAY['artifacts:write']::varchar[]"
           )

    create constraint(:api_tokens, :api_tokens_name_length,
             check: "char_length(name) BETWEEN 1 AND 64"
           )

    execute(
      "ALTER TABLE api_tokens ALTER COLUMN tenant_id SET DEFAULT #{@tenant_expression}",
      "ALTER TABLE api_tokens ALTER COLUMN tenant_id SET DEFAULT 'standalone'"
    )

    execute("ALTER TABLE api_tokens ENABLE ROW LEVEL SECURITY", "")
    execute("ALTER TABLE api_tokens FORCE ROW LEVEL SECURITY", "")

    execute(
      "CREATE POLICY api_tokens_tenant_isolation ON api_tokens " <>
        "USING (tenant_id = #{@tenant_expression}) " <>
        "WITH CHECK (tenant_id = #{@tenant_expression})",
      "DROP POLICY IF EXISTS api_tokens_tenant_isolation ON api_tokens"
    )
  end
end
