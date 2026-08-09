defmodule Robine.Repo.Migrations.CreateWorkflowRevisions do
  use Ecto.Migration

  def change do
    create table(:workflow_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :pipeline_id, references(:pipelines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :path, :string, null: false
      add :source, :text, null: false
      add :digest, :string, size: 64, null: false
      add :normalized_graph, :map, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create unique_index(:workflow_revisions, [:pipeline_id])
    create index(:workflow_revisions, [:digest])
  end
end
