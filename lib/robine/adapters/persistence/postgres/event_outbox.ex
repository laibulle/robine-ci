defmodule Robine.Adapters.Persistence.Postgres.EventOutbox do
  @moduledoc false
  @behaviour Robine.Pipelines.Ports.EventOutbox

  alias Robine.Adapters.Persistence.Postgres.Schemas.OutboxEvent
  alias Robine.Adapters.Background.OutboxDeliveryWorker
  alias Robine.Pipelines.Domain.{PipelineCreated, PipelineProjectionRequested}
  alias Robine.Repo
  import Ecto.Query

  @impl true
  def append(%PipelineCreated{} = event) do
    persist(%{
      id: event.event_id,
      event_type: "pipeline.created",
      aggregate_id: event.pipeline_id,
      occurred_at: event.occurred_at,
      payload: %{
        "pipeline_id" => event.pipeline_id,
        "repository_id" => event.repository_id
      }
    })
  end

  def append(%PipelineProjectionRequested{} = event) do
    persist(%{
      id: event.event_id,
      event_type: "pipeline.projection_requested",
      aggregate_id: event.pipeline_id,
      occurred_at: event.occurred_at,
      payload: %{"pipeline_id" => event.pipeline_id, "dispatch" => event.dispatch}
    })
  end

  defp persist(attributes) do
    with {:ok, _event} <-
           %OutboxEvent{}
           |> OutboxEvent.changeset(attributes)
           |> Repo.insert(),
         {:ok, _job} <-
           %{event_id: attributes.id}
           |> OutboxDeliveryWorker.new()
           |> Oban.insert() do
      :ok
    else
      {:error, changeset_or_job} -> {:error, {:outbox, changeset_or_job}}
    end
  end

  @impl true
  def get(event_id) when is_binary(event_id) do
    case Repo.get(OutboxEvent, event_id) do
      nil ->
        {:error, :not_found}

      event ->
        {:ok,
         %{
           id: event.id,
           event_type: event.event_type,
           aggregate_id: event.aggregate_id,
           payload: event.payload,
           occurred_at: event.occurred_at,
           delivered_at: event.delivered_at
         }}
    end
  end

  @impl true
  def mark_delivered(event_id, delivered_at) do
    case Repo.get(OutboxEvent, event_id) do
      nil ->
        {:error, :not_found}

      %{delivered_at: %DateTime{}} ->
        :ok

      event ->
        event
        |> Ecto.Changeset.change(delivered_at: delivered_at)
        |> Repo.update()
        |> case do
          {:ok, _event} -> :ok
          {:error, changeset} -> {:error, {:outbox, changeset}}
        end
    end
  end

  @impl true
  def reconcile_pending(limit) do
    event_ids =
      Repo.all(
        from event in OutboxEvent,
          where: is_nil(event.delivered_at),
          order_by: [asc: event.occurred_at],
          limit: ^limit,
          select: event.id
      )

    Enum.reduce_while(event_ids, {:ok, 0}, fn event_id, {:ok, count} ->
      case %{event_id: event_id} |> OutboxDeliveryWorker.new() |> Oban.insert() do
        {:ok, %Oban.Job{conflict?: true}} -> {:cont, {:ok, count}}
        {:ok, _job} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, {:outbox_reconciliation, reason}}}
      end
    end)
  end
end
