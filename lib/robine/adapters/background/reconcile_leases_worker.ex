defmodule Robine.Adapters.Background.ReconcileLeasesWorker do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 5, unique: [period: 50]

  alias Robine.Pipelines
  alias Robine.Adapters.Background.TenantJob

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    TenantJob.run(
      job,
      __MODULE__,
      "lease-reconciliation:#{System.system_time(:second)}",
      fn context ->
        case Pipelines.reconcile_expired_leases(%{limit: 100}, context) do
          {:ok, _count} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    )
  end
end
