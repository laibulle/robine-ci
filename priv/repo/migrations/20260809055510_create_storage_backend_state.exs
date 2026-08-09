defmodule Robine.Repo.Migrations.CreateStorageBackendState do
  use Ecto.Migration

  def change do
    create table(:storage_backend_states, primary_key: false) do
      add :id, :string, primary_key: true
      add :backend, :string, null: false
      add :namespace_digest, :string, null: false
      add :acknowledged_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end
  end
end
