defmodule Robine.Repo.Migrations.AddSourceRefToPipelines do
  use Ecto.Migration

  def change do
    alter table(:pipelines) do
      add :source_ref, :string
    end
  end
end
