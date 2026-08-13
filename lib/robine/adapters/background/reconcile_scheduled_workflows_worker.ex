defmodule Robine.Adapters.Background.ReconcileScheduledWorkflowsWorker do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 5, unique: [period: 50]

  alias Robine.Repositories
  alias Robine.Adapters.Background.TenantJob

  @impl Oban.Worker
  def perform(%Oban.Job{id: id} = job) do
    TenantJob.run(
      job,
      __MODULE__,
      "scheduled-workflows:#{id || Ecto.UUID.generate()}",
      fn context ->
        case Repositories.reconcile_scheduled_workflows(%{}, context) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    )
  end
end
