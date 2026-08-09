defmodule Robine.Repo.Migrations.AddLabelsToRemoteRunners do
  use Ecto.Migration

  def change do
    alter table(:remote_runners) do
      add :labels, {:array, :string}, null: false, default: []
    end

    create index(:remote_runners, [:admin_state, :last_seen_at])
  end
end
