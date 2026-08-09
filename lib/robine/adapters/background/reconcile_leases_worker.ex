defmodule Robine.Adapters.Background.ReconcileLeasesWorker do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 5, unique: [period: 50]

  alias Robine.Pipelines
  alias Robine.Runtime.Dependencies

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    context =
      Dependencies.context(
        %{id: "system:lease-reconciler", role: :administrator},
        "lease-reconciliation:#{System.system_time(:second)}"
      )

    case Pipelines.reconcile_expired_leases(%{limit: 100}, context) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
