defmodule Robine.Repo.Migrations.MakeApiTokensGlobal do
  use Ecto.Migration

  def up do
    drop index(:api_tokens, [:tenant_id, :repository_id, :inserted_at])

    alter table(:api_tokens) do
      remove :repository_id
    end

    create index(:api_tokens, [:tenant_id, :inserted_at])
  end

  def down do
    drop index(:api_tokens, [:tenant_id, :inserted_at])

    alter table(:api_tokens) do
      add :repository_id,
          references(:github_repositories, type: :binary_id, on_delete: :delete_all)
    end

    create index(:api_tokens, [:tenant_id, :repository_id, :inserted_at])
  end
end
