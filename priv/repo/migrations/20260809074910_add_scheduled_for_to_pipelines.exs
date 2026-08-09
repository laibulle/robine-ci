defmodule Robine.Repo.Migrations.AddScheduledForToPipelines do
  use Ecto.Migration

  def change do
    alter table(:pipelines) do
      add :scheduled_for, :utc_datetime_usec
    end

    create index(:pipelines, [:trigger, :scheduled_for])
  end
end
