defmodule Robine.Repo.Migrations.CreateOIDCIdentities do
  use Ecto.Migration

  def change do
    create table(:oidc_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :issuer, :string, null: false
      add :subject, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:oidc_identities, [:issuer, :subject])
    create index(:oidc_identities, [:user_id])
  end
end
