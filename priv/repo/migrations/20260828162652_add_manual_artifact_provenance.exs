defmodule Robine.Repo.Migrations.AddManualArtifactProvenance do
  use Ecto.Migration

  def change do
    alter table(:artifacts) do
      modify :attempt_id, :binary_id, null: true, from: {:binary_id, null: false}
      add :source, :string, null: false, default: "ci"
      add :uploaded_by_id, :binary_id
      add :content_type, :string, null: false, default: "application/gzip"
    end

    create constraint(:artifacts, :artifacts_valid_provenance,
             check:
               "(source = 'ci' AND attempt_id IS NOT NULL AND uploaded_by_id IS NULL) OR " <>
                 "(source = 'manual' AND attempt_id IS NULL AND uploaded_by_id IS NOT NULL)"
           )

    create index(:artifacts, [:repository_id, :source, :created_at])
  end
end
