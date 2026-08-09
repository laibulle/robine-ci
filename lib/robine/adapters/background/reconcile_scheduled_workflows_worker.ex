defmodule Robine.Adapters.Background.ReconcileScheduledWorkflowsWorker do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 5, unique: [period: 50]

  alias Robine.Repositories
  alias Robine.Runtime.Dependencies

  @impl Oban.Worker
  def perform(%Oban.Job{id: id}) do
    context =
      Dependencies.context(
        %{id: "system:scheduler", role: :administrator},
        "scheduled-workflows:#{id || Ecto.UUID.generate()}"
      )

    case Repositories.reconcile_scheduled_workflows(%{}, context) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
