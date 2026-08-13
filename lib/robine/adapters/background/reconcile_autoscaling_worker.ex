defmodule Robine.Adapters.Background.ReconcileAutoscalingWorker do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 5, unique: [period: 50]

  alias Robine.Autoscaling
  alias Robine.Adapters.Background.TenantJob

  @impl Oban.Worker
  def perform(%Oban.Job{id: id} = job) do
    TenantJob.run(job, __MODULE__, "autoscaling-reconciliation:#{id}", fn context ->
      case Autoscaling.reconcile(%{}, context) do
        {:ok, result} ->
          :telemetry.execute(
            [:robine, :autoscaling, :reconcile],
            %{policies: result.policies, effects: result.effects},
            %{outcome: :ok}
          )

          :ok

        {:error, reason} ->
          :telemetry.execute(
            [:robine, :autoscaling, :reconcile],
            %{policies: 0, effects: 0},
            %{outcome: :error}
          )

          {:error, reason}
      end
    end)
  end
end
