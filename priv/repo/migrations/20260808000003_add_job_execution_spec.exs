defmodule Robine.Repo.Migrations.AddJobExecutionSpec do
  use Ecto.Migration

  def change do
    alter table(:pipeline_jobs) do
      add :execution_spec, :map, null: false, default: %{}
    end
  end
end
