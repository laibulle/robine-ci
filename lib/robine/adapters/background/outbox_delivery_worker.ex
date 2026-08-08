defmodule Robine.Adapters.Background.OutboxDeliveryWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :outbox,
    max_attempts: 10,
    unique: [period: :infinity, keys: [:event_id]]

  alias Robine.Pipelines
  alias Robine.Adapters.Background.RunNextJobWorker
  alias Robine.Runtime.Dependencies

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id}}) do
    context =
      Dependencies.context(
        %{id: "system:outbox", role: :administrator},
        "outbox:#{event_id}"
      )

    case Pipelines.deliver_event(%{event_id: event_id}, context) do
      {:ok, :delivered} ->
        case Oban.insert(RunNextJobWorker.new(%{})) do
          {:ok, _job} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:cancel, :event_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
