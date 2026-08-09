defmodule Robine.Adapters.Background.ReconcileRunnerResourcesWorker do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 5, unique: [period: 240]

  alias Robine.{Execution, Pipelines}
  alias Robine.Runtime.Dependencies

  @impl Oban.Worker
  def perform(%Oban.Job{id: id}) do
    context =
      Dependencies.context(
        %{id: "system:runner-reconciler", role: :administrator},
        "runner-reconciliation:#{id}"
      )

    with {:ok, active_ids} <- Pipelines.list_active_attempt_ids(%{}, context),
         {:ok, _result} <-
           Execution.reconcile_resources(%{active_attempt_ids: active_ids}, context) do
      :ok
    end
  end
end
