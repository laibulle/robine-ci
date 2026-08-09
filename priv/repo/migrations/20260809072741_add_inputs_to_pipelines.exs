defmodule Robine.Repo.Migrations.AddInputsToPipelines do
  use Ecto.Migration

  def change do
    alter table(:pipelines) do
      add :inputs, :map, null: false, default: %{}
    end
  end
end
