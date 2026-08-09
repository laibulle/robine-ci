defmodule Robine.Repo.Migrations.AddSourcesToWorkflowRevisions do
  use Ecto.Migration

  def change do
    alter table(:workflow_revisions) do
      add :included_sources, :map, null: false, default: %{}
    end
  end
end
