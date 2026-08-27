defmodule Robine.Repo.Migrations.CreatePublicationPoliciesAndPublications do
  use Ecto.Migration

  @tenant_expression "COALESCE(NULLIF(current_setting('robine.tenant_id', true), ''), 'standalone')"

  def change do
    create table(:publication_policies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id,
          references(:github_repositories, type: :binary_id, on_delete: :delete_all), null: false

      add :enabled, :boolean, null: false, default: false
      add :public_slug, :string, null: false
      add :tenant_id, :text, null: false, default: "standalone"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:publication_policies, [:tenant_id, :repository_id])
    create unique_index(:publication_policies, [:tenant_id, :public_slug])

    create table(:publications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id,
          references(:github_repositories, type: :binary_id, on_delete: :delete_all), null: false

      add :pipeline_id, references(:pipelines, type: :binary_id, on_delete: :nilify_all)
      add :job_id, references(:pipeline_jobs, type: :binary_id, on_delete: :nilify_all)
      add :attempt_id, references(:job_attempts, type: :binary_id, on_delete: :nilify_all)

      add :workflow_revision_id,
          references(:workflow_revisions, type: :binary_id, on_delete: :nilify_all)

      add :release, :string, null: false
      add :filename, :string, null: false
      add :content_type, :string, null: false, default: "application/octet-stream"
      add :digest, :string, null: false
      add :size, :bigint, null: false
      add :status, :string, null: false
      add :source_commit, :string, null: false
      add :source_tag, :string, null: false
      add :public_url, :string
      add :published_at, :utc_datetime_usec
      add :withdrawn_at, :utc_datetime_usec
      add :tenant_id, :text, null: false, default: "standalone"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:publications, [:tenant_id, :repository_id, :release, :filename],
             name: :publications_immutable_identity_index
           )

    create index(:publications, [:tenant_id, :repository_id, :inserted_at])

    for table <- ~w(publication_policies publications) do
      execute(
        "ALTER TABLE #{table} ALTER COLUMN tenant_id SET DEFAULT #{@tenant_expression}",
        "ALTER TABLE #{table} ALTER COLUMN tenant_id SET DEFAULT 'standalone'"
      )

      execute("ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY", "")
      execute("ALTER TABLE #{table} FORCE ROW LEVEL SECURITY", "")

      execute(
        "CREATE POLICY #{table}_tenant_isolation ON #{table} " <>
          "USING (tenant_id = #{@tenant_expression}) " <>
          "WITH CHECK (tenant_id = #{@tenant_expression})",
        "DROP POLICY IF EXISTS #{table}_tenant_isolation ON #{table}"
      )
    end
  end
end
