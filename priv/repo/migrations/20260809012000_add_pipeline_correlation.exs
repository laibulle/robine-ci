defmodule Robine.Repo.Migrations.AddPipelineCorrelation do
  use Ecto.Migration

  def change do
    alter table(:pipelines) do
      add :correlation_id, :string, null: false, default: "legacy"
    end
  end
end
