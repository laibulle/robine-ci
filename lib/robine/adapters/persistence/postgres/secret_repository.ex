defmodule Robine.Adapters.Persistence.Postgres.SecretRepository do
  @moduledoc false
  @behaviour Robine.Secrets.Ports.Repository
  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.AuditEvent
  alias Robine.Adapters.Persistence.Postgres.Schemas.Secret, as: SecretSchema
  alias Robine.Repo

  @impl true
  def upsert(secret, audit) do
    Repo.transaction(fn ->
      changeset = SecretSchema.changeset(%SecretSchema{}, Map.from_struct(secret))

      case Repo.insert(changeset,
             on_conflict: [
               set: [
                 id: secret.id,
                 ciphertext: secret.ciphertext,
                 nonce: secret.nonce,
                 tag: secret.tag,
                 key_version: secret.key_version,
                 allowed_repository_ids: secret.allowed_repository_ids,
                 inserted_at: secret.inserted_at
               ]
             ],
             conflict_target: [:scope, :repository_id, :name],
             returning: true
           ) do
        {:ok, stored} ->
          attributes = Map.merge(audit, %{target_type: "secret", target_id: stored.id})

          case Repo.insert(AuditEvent.changeset(%AuditEvent{}, attributes)) do
            {:ok, _event} -> :ok
            {:error, audit_changeset} -> Repo.rollback({:audit, audit_changeset})
          end

        {:error, secret_changeset} ->
          Repo.rollback({:secret, secret_changeset})
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def find_authorized(repository_id, names) do
    schemas =
      Repo.all(
        from secret in SecretSchema,
          where:
            secret.name in ^names and
              ((secret.scope == :repository and secret.repository_id == ^repository_id) or
                 (secret.scope == :instance and ^repository_id in secret.allowed_repository_ids))
      )

    {:ok, Enum.map(schemas, &to_domain/1)}
  end

  defp to_domain(schema) do
    struct!(Robine.Secrets.Domain.Secret, %{
      id: schema.id,
      name: schema.name,
      scope: schema.scope,
      repository_id: schema.repository_id,
      allowed_repository_ids: schema.allowed_repository_ids,
      ciphertext: schema.ciphertext,
      nonce: schema.nonce,
      tag: schema.tag,
      key_version: schema.key_version,
      inserted_at: schema.inserted_at
    })
  end
end
