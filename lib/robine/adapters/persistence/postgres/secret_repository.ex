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
             conflict_target: {:unsafe_fragment, "(tenant_id, scope, repository_id, name)"},
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

    missing_count = length(Enum.uniq(names)) - length(schemas)

    if missing_count > 0 do
      :telemetry.execute(
        [:robine, :secrets, :missing_reference],
        %{count: missing_count},
        %{}
      )
    end

    {:ok, Enum.map(schemas, &to_domain/1)}
  end

  @impl true
  def find_instance(names) do
    schemas =
      Repo.all(
        from secret in SecretSchema,
          where: secret.scope == :instance and secret.name in ^names
      )

    {:ok, Enum.map(schemas, &to_domain/1)}
  end

  @impl true
  def list_metadata(repository_id) do
    metadata =
      Repo.all(
        from secret in SecretSchema,
          where:
            (secret.scope == :repository and secret.repository_id == ^repository_id) or
              (secret.scope == :instance and ^repository_id in secret.allowed_repository_ids),
          order_by: [asc: secret.name],
          select: %{
            id: secret.id,
            name: secret.name,
            scope: secret.scope,
            repository_id: secret.repository_id,
            inserted_at: secret.inserted_at
          }
      )

    {:ok, metadata}
  end

  @impl true
  def list_for_rotation(target_version, cursor, limit) do
    query =
      from secret in SecretSchema,
        where: secret.key_version != ^target_version,
        order_by: [asc: secret.id],
        limit: ^limit

    query = if cursor, do: from(secret in query, where: secret.id > ^cursor), else: query
    {:ok, Repo.all(query) |> Enum.map(&to_domain/1)}
  end

  @impl true
  def rotate(secret, previous_version, audit) do
    Repo.transaction(fn ->
      query = from stored in SecretSchema, where: stored.id == ^secret.id, lock: "FOR UPDATE"

      case Repo.one(query) do
        nil ->
          Repo.rollback(:not_found)

        %{key_version: version} when version != previous_version ->
          Repo.rollback(:rotation_conflict)

        stored ->
          changes =
            Ecto.Changeset.change(stored,
              ciphertext: secret.ciphertext,
              nonce: secret.nonce,
              tag: secret.tag,
              key_version: secret.key_version
            )

          with {:ok, _stored} <- Repo.update(changes),
               attributes = Map.merge(audit, %{target_type: "secret", target_id: secret.id}),
               {:ok, _event} <-
                 Repo.insert(AuditEvent.changeset(%AuditEvent{}, attributes)) do
            :ok
          else
            {:error, changeset} -> Repo.rollback({:secret_rotation, changeset})
          end
      end
    end)
    |> case do
      {:ok, :ok} ->
        :telemetry.execute(
          [:robine, :secrets, :rotation],
          %{count: 1},
          %{from_version: previous_version, to_version: secret.key_version}
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
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
