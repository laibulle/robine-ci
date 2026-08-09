defmodule Robine.Adapters.Background.OutboxDeliveryWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :outbox,
    max_attempts: 10,
    unique: [
      period: :infinity,
      keys: [:event_id],
      states: :incomplete
    ]

  alias Robine.Pipelines
  alias Robine.Adapters.Background.RunNextJobWorker
  alias Robine.Runtime.Dependencies

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    base = trunc(:math.pow(2, max(attempt - 1, 0))) * 15
    min(base, 1_790) + :rand.uniform(11) - 1
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id}}) do
    context =
      Dependencies.context(
        %{id: "system:outbox", role: :administrator},
        "outbox:#{event_id}"
      )

    result =
      case Pipelines.deliver_event(%{event_id: event_id}, context) do
        {:ok, :dispatch} ->
          case Oban.insert(RunNextJobWorker.new(%{})) do
            {:ok, _job} -> :ok
            {:error, reason} -> {:error, reason}
          end

        {:ok, :none} ->
          :ok

        {:error, :not_found} ->
          {:cancel, :event_not_found}

        {:error, reason} ->
          {:error, reason}
      end

    :telemetry.execute(
      [:robine, :outbox, :delivery],
      %{count: 1},
      %{outcome: outcome(result)}
    )

    result
  end

  defp outcome(:ok), do: :ok
  defp outcome({:cancel, _reason}), do: :cancelled
  defp outcome({:error, _reason}), do: :error
end
