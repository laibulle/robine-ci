defmodule Robine.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14, prefix: prefix() || "public")
  def down, do: Oban.Migration.down(version: 1, prefix: prefix() || "public")
end
