defmodule Robine.Adapters.Persistence.Postgres.GitHubRepository do
  @moduledoc false
  @behaviour Robine.Repositories.Ports.Repository
  import Ecto.Query

  alias Robine.Adapters.Background.ProcessGitHubDeliveryWorker

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    GitHubCheck,
    GitHubDelivery,
    GitHubRepository
  }

  alias Robine.Repo

  @impl true
  def upsert_repository(repository) do
    attributes = Map.from_struct(repository)

    GitHubRepository.changeset(%GitHubRepository{}, attributes)
    |> Repo.insert(
      on_conflict: [
        set: [
          installation_id: repository.installation_id,
          owner: repository.owner,
          name: repository.name,
          full_name: repository.full_name,
          trusted: repository.trusted
        ]
      ],
      conflict_target: [:provider_id]
    )
    |> normalize(:repository_persistence)
  end

  @impl true
  def get_by_provider_id(provider_id) do
    case Repo.one(
           from repository in GitHubRepository, where: repository.provider_id == ^provider_id
         ) do
      nil -> {:error, :not_found}
      schema -> {:ok, repository_to_domain(schema)}
    end
  end

  @impl true
  def get_by_id(id) do
    case Repo.get(GitHubRepository, id) do
      nil -> {:error, :not_found}
      schema -> {:ok, repository_to_domain(schema)}
    end
  end

  @impl true
  def list do
    repositories =
      Repo.all(from repository in GitHubRepository, order_by: [asc: repository.full_name])

    {:ok, Enum.map(repositories, &repository_to_domain/1)}
  end

  @impl true
  def accept_delivery(delivery) do
    Repo.transaction(fn ->
      {count, _rows} =
        Repo.insert_all(
          GitHubDelivery,
          [Map.from_struct(delivery)],
          on_conflict: :nothing,
          conflict_target: [:id]
        )

      if count == 0 do
        :duplicate
      else
        case %{delivery_id: delivery.id} |> ProcessGitHubDeliveryWorker.new() |> Oban.insert() do
          {:ok, _job} -> :accepted
          {:error, reason} -> Repo.rollback({:delivery_job, reason})
        end
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_delivery(id) do
    case Repo.get(GitHubDelivery, id) do
      nil -> {:error, :not_found}
      schema -> {:ok, delivery_to_domain(schema)}
    end
  end

  @impl true
  def finish_delivery(id, status, processed_at, failure) do
    case Repo.get(GitHubDelivery, id) do
      nil ->
        {:error, :not_found}

      schema ->
        schema
        |> Ecto.Changeset.change(status: status, processed_at: processed_at, failure: failure)
        |> Repo.update()
        |> normalize(:delivery_persistence)
    end
  end

  @impl true
  def get_check(external_key) do
    case Repo.one(from check in GitHubCheck, where: check.external_key == ^external_key) do
      nil -> {:error, :not_found}
      check -> {:ok, Map.from_struct(check) |> Map.drop([:__meta__])}
    end
  end

  @impl true
  def upsert_check(attributes) do
    GitHubCheck.changeset(%GitHubCheck{}, attributes)
    |> Repo.insert(
      on_conflict: [
        set: [
          provider_check_id: attributes.provider_check_id,
          status: attributes.status,
          conclusion: attributes.conclusion,
          updated_at: DateTime.utc_now()
        ]
      ],
      conflict_target: [:external_key]
    )
    |> normalize(:check_persistence)
  end

  defp normalize({:ok, _schema}, _tag), do: :ok
  defp normalize({:error, changeset}, tag), do: {:error, {tag, changeset}}

  defp repository_to_domain(schema) do
    struct!(Robine.Repositories.Domain.Repository, %{
      id: schema.id,
      provider_id: schema.provider_id,
      installation_id: schema.installation_id,
      owner: schema.owner,
      name: schema.name,
      full_name: schema.full_name,
      trusted: schema.trusted,
      inserted_at: schema.inserted_at
    })
  end

  defp delivery_to_domain(schema) do
    struct!(Robine.Repositories.Domain.Delivery, %{
      id: schema.id,
      event: schema.event,
      payload: schema.payload,
      status: schema.status,
      received_at: schema.received_at,
      processed_at: schema.processed_at,
      failure: schema.failure
    })
  end
end
