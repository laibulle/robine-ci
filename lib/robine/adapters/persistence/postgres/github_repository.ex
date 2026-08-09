defmodule Robine.Adapters.Persistence.Postgres.GitHubRepository do
  @moduledoc false
  @behaviour Robine.Repositories.Ports.Repository
  import Ecto.Query

  alias Robine.Adapters.Background.ProcessGitHubDeliveryWorker

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    AuditEvent,
    GitHubCheck,
    GitHubDelivery,
    GitHubRepository,
    ScheduleReconciliationState
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
          provider: repository.provider,
          provider_instance: repository.provider_instance,
          owner: repository.owner,
          name: repository.name,
          full_name: repository.full_name,
          trusted: repository.trusted
        ]
      ],
      conflict_target: [:provider, :provider_instance, :provider_id]
    )
    |> normalize(:repository_persistence)
  end

  @impl true
  def get_by_provider_id(provider_id) do
    get_by_provider(:github, "default", provider_id)
  end

  @impl true
  def get_by_provider(provider, provider_instance, provider_id) do
    case Repo.one(
           from repository in GitHubRepository,
             where:
               repository.provider == ^provider and
                 repository.provider_instance == ^provider_instance and
                 repository.provider_id == ^provider_id
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
    get_check(:github, "default", external_key)
  end

  @impl true
  def get_check(provider, provider_instance, external_key) do
    case Repo.one(
           from check in GitHubCheck,
             where:
               check.provider == ^provider and check.provider_instance == ^provider_instance and
                 check.external_key == ^external_key
         ) do
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
      conflict_target: [:provider, :provider_instance, :external_key]
    )
    |> normalize(:check_persistence)
  end

  @impl true
  def audit_manual_launch(attributes) do
    AuditEvent.changeset(%AuditEvent{}, %{
      actor_id: attributes.actor_id,
      action: "workflow.manual_launch",
      target_type: "pipeline",
      target_id: attributes.pipeline_id,
      occurred_at: attributes.occurred_at,
      metadata: %{
        repository_id: attributes.repository_id,
        workflow_path: attributes.workflow_path,
        commit_sha: attributes.commit_sha,
        correlation_id: attributes.correlation_id,
        input_count: attributes.input_count,
        outcome: "created_or_reused"
      }
    })
    |> Repo.insert()
    |> normalize(:manual_launch_audit)
  end

  @impl true
  def get_schedule_cursor do
    case Repo.get(ScheduleReconciliationState, "workflows") do
      nil -> {:ok, nil}
      state -> {:ok, state.cursor}
    end
  end

  @impl true
  def advance_schedule_cursor(nil, %DateTime{} = cursor) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    Repo.transaction(fn ->
      {updated, _rows} =
        Repo.update_all(
          from(state in ScheduleReconciliationState,
            where: state.key == "workflows" and is_nil(state.cursor)
          ),
          set: [
            cursor: cursor,
            last_attempt_at: now,
            last_success_at: now,
            last_failure: nil,
            updated_at: now
          ]
        )

      if updated == 1 do
        :ok
      else
        case Repo.insert_all(
               ScheduleReconciliationState,
               [
                 %{
                   key: "workflows",
                   cursor: cursor,
                   last_attempt_at: now,
                   last_success_at: now,
                   last_failure: nil,
                   inserted_at: now,
                   updated_at: now
                 }
               ],
               on_conflict: :nothing,
               conflict_target: [:key]
             ) do
          {1, _rows} -> :ok
          {0, _rows} -> Repo.rollback(:cursor_conflict)
        end
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, :cursor_conflict} -> {:error, :cursor_conflict}
      {:error, reason} -> {:error, {:schedule_cursor_persistence, reason}}
    end
  end

  def advance_schedule_cursor(%DateTime{} = expected, %DateTime{} = cursor) do
    {count, _rows} =
      Repo.update_all(
        from(state in ScheduleReconciliationState,
          where: state.key == "workflows" and state.cursor == ^expected
        ),
        set: [
          cursor: cursor,
          last_attempt_at: cursor,
          last_success_at: cursor,
          last_failure: nil,
          updated_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
        ]
      )

    if count == 1, do: :ok, else: {:error, :cursor_conflict}
  end

  @impl true
  def record_schedule_failure(failure, %DateTime{} = attempted_at)
      when is_binary(failure) and byte_size(failure) <= 255 do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    case Repo.insert_all(
           ScheduleReconciliationState,
           [
             %{
               key: "workflows",
               cursor: nil,
               last_attempt_at: attempted_at,
               last_failure: failure,
               inserted_at: now,
               updated_at: now
             }
           ],
           on_conflict: [
             set: [last_attempt_at: attempted_at, last_failure: failure, updated_at: now]
           ],
           conflict_target: [:key]
         ) do
      {1, _rows} -> :ok
      {_count, _rows} -> :ok
    end
  end

  @impl true
  def audit_scheduled_launch(attributes) do
    AuditEvent.changeset(%AuditEvent{}, %{
      actor_id: attributes.actor_id,
      action: "workflow.scheduled_launch",
      target_type: "pipeline",
      target_id: attributes.pipeline_id,
      occurred_at: attributes.occurred_at,
      metadata: %{
        repository_id: attributes.repository_id,
        workflow_path: attributes.workflow_path,
        commit_sha: attributes.commit_sha,
        cron: attributes.cron,
        scheduled_for: DateTime.to_iso8601(attributes.scheduled_for),
        correlation_id: attributes.correlation_id,
        outcome: "created_or_reused"
      }
    })
    |> Repo.insert()
    |> normalize(:scheduled_launch_audit)
  end

  defp normalize({:ok, _schema}, _tag), do: :ok
  defp normalize({:error, changeset}, tag), do: {:error, {tag, changeset}}

  defp repository_to_domain(schema) do
    struct!(Robine.Repositories.Domain.Repository, %{
      id: schema.id,
      provider: schema.provider,
      provider_instance: schema.provider_instance,
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
      provider: schema.provider,
      provider_instance: schema.provider_instance,
      provider_delivery_id: schema.provider_delivery_id,
      event: schema.event,
      payload: schema.payload,
      status: schema.status,
      received_at: schema.received_at,
      processed_at: schema.processed_at,
      failure: schema.failure
    })
  end
end
