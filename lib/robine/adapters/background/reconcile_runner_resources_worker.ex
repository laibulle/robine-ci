defmodule Robine.Adapters.Background.ReconcileRunnerResourcesWorker do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 5, unique: [period: 240]

  alias Robine.{Execution, Pipelines}
  alias Robine.Adapters.Background.TenantJob

  @impl Oban.Worker
  def perform(%Oban.Job{id: id} = job) do
    if Application.fetch_env!(:robine, :local_runner_enabled) do
      TenantJob.run(job, __MODULE__, "runner-reconciliation:#{id}", fn context ->
        with {:ok, active_ids} <- Pipelines.list_active_attempt_ids(%{}, context),
             {:ok, result} <-
               Execution.reconcile_resources(%{active_attempt_ids: active_ids}, context) do
          :telemetry.execute(
            [:robine, :runner, :orphans],
            %{
              containers: result.containers_removed,
              volumes: result.volumes_removed
            },
            %{}
          )

          :ok
        end
      end)
    else
      :ok
    end
  end
end
