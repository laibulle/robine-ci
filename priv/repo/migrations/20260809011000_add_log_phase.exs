defmodule Robine.Repo.Migrations.AddLogPhase do
  use Ecto.Migration

  def change do
    alter table(:log_chunks) do
      add :phase, :string, null: false, default: "execution"
    end

    create index(:log_chunks, [:attempt_id, :phase, :step_position, :sequence])
  end
end
