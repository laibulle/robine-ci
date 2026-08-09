defmodule Robine.Repo.Migrations.AddPipelineExecutionMetadata do
  use Ecto.Migration

  def change do
    alter table(:pipelines) do
      add :trigger, :string, null: false, default: "manual"
      add :actor, :string, null: false, default: "system"
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
    end
  end
end
