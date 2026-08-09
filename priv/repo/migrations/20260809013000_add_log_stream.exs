defmodule Robine.Repo.Migrations.AddLogStream do
  use Ecto.Migration

  def change do
    alter table(:log_chunks) do
      add :stream, :string, null: false, default: "combined"
    end

    create index(:log_chunks, [:attempt_id, :stream, :sequence])
  end
end
