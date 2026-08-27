defmodule Robine.Adapters.Persistence.Postgres.PublicationRepository do
  @moduledoc false
  @behaviour Robine.Publications.Ports.Repository
  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{AuditEvent, Publication, PublicationPolicy}
  alias Robine.Publications.Domain.RepositoryPolicy
  alias Robine.Repo

  @impl true
  def get_policy(repository_id) when is_binary(repository_id) do
    case Repo.one(from policy in PublicationPolicy, where: policy.repository_id == ^repository_id) do
      nil -> {:ok, nil}
      schema -> RepositoryPolicy.new(Map.from_struct(schema))
    end
  end

  def get_policy(_repository_id), do: {:error, :invalid_repository_id}

  @impl true
  def upsert_policy(%RepositoryPolicy{} = policy, audit) do
    Repo.transaction(fn ->
      with {:ok, _stored} <-
             PublicationPolicy.changeset(%PublicationPolicy{}, Map.from_struct(policy))
             |> Repo.insert(
               on_conflict: {:replace, [:enabled, :public_slug, :updated_at]},
               conflict_target: {:unsafe_fragment, "(tenant_id, repository_id)"}
             ),
           {:ok, _audit} <-
             AuditEvent.changeset(%AuditEvent{}, %{
               actor_id: audit.actor_id,
               action: "publication.policy_configured",
               target_type: "repository",
               target_id: policy.repository_id,
               occurred_at: policy.updated_at,
               metadata: %{
                 correlation_id: audit.correlation_id,
                 enabled: policy.enabled,
                 public_slug: policy.public_slug
               }
             })
             |> Repo.insert() do
        :ok
      else
        {:error, changeset} -> Repo.rollback({:publication_persistence, changeset})
      end
    end)
    |> unwrap()
  end

  @impl true
  def list_publications(repository_id) when is_binary(repository_id) do
    {:ok,
     Repo.all(
       from publication in Publication,
         where: publication.repository_id == ^repository_id,
         order_by: [desc: publication.inserted_at]
     )
     |> Enum.map(&publication_view/1)}
  end

  def list_publications(_repository_id), do: {:error, :invalid_repository_id}

  @impl true
  def find_latest_published(public_slug, filename)
      when is_binary(public_slug) and is_binary(filename) do
    publications =
      Repo.all(
        from publication in Publication,
          join: policy in PublicationPolicy,
          on: policy.repository_id == publication.repository_id,
          where:
            policy.enabled == true and policy.public_slug == ^public_slug and
              publication.filename == ^filename and publication.status == :published and
              not is_nil(publication.public_url),
          order_by: [
            desc_nulls_last: publication.published_at,
            desc: publication.inserted_at
          ]
      )

    case Enum.find(publications, &stable_release?(&1.release)) do
      nil -> {:error, :not_found}
      publication -> {:ok, publication_view(publication)}
    end
  end

  def find_latest_published(_public_slug, _filename), do: {:error, :not_found}

  defp publication_view(schema) do
    schema
    |> Map.from_struct()
    |> Map.take([
      :id,
      :release,
      :filename,
      :content_type,
      :digest,
      :size,
      :status,
      :source_commit,
      :source_tag,
      :public_url,
      :published_at,
      :withdrawn_at,
      :inserted_at
    ])
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, reason}), do: {:error, reason}

  defp stable_release?("v" <> version) do
    case Version.parse(version) do
      {:ok, %Version{pre: []}} -> true
      _result -> false
    end
  end

  defp stable_release?(_release), do: false
end
