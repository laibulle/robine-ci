defmodule Robine.Adapters.Background.RunNextDeploymentWorker do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 5]

  alias Robine.Adapters.Background.TenantJob
  alias Robine.Adapters.Runner.RemoteDeploymentOffer
  alias Robine.{Deployments, Runners}
  alias Robine.Runtime.{Dependencies, Events}

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    TenantJob.run(job, __MODULE__, "deployment-dispatch:#{Ecto.UUID.generate()}", fn context ->
      dispatch(context)
    end)
  end

  defp dispatch(context) do
    lease_seconds =
      Application.fetch_env!(:robine, :runner_control) |> Keyword.fetch!(:lease_seconds)

    with {:ok, queued} <- Deployments.next_queued_deployment(%{}, context),
         {:ok, runner} <-
           Runners.select_deployment_runner(%{labels: queued.runner_labels}, context),
         {:ok, assigned} <-
           Deployments.assign_deployment(
             %{
               deployment_id: queued.id,
               runner_id: runner.id,
               lease_seconds: lease_seconds
             },
             context
           ),
         runner_context =
           Dependencies.runner_context(
             context.tenant_id,
             runner.id,
             "deployment:#{assigned.id}"
           ),
         {:ok, offer} <- RemoteDeploymentOffer.build(assigned.id, runner_context),
         :ok <- Events.broadcast("runner:#{runner.id}", {:deployment_offer, offer}) do
      :ok
    else
      {:error, :none} -> :ok
      {:error, :deployment_already_active} -> {:snooze, 1}
      {:error, reason} -> {:error, reason}
    end
  end
end
