defmodule Robine.Adapters.Background.ReconcileOutboxWorker do
  @moduledoc false
  use Oban.Worker, queue: :outbox, max_attempts: 5, unique: [period: 50]

  alias Robine.Pipelines
  alias Robine.Runtime.Dependencies

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    context =
      Dependencies.context(
        %{id: "system:outbox-reconciler", role: :administrator},
        "outbox-reconciliation:#{Ecto.UUID.generate()}"
      )

    case Pipelines.reconcile_outbox(%{limit: 100}, context) do
      {:ok, count} ->
        :telemetry.execute([:robine, :outbox, :reconciliation], %{count: count}, %{})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
