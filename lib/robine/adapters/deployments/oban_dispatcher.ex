defmodule Robine.Adapters.Deployments.ObanDispatcher do
  @moduledoc false
  @behaviour Robine.Deployments.Ports.Dispatcher

  alias Robine.Adapters.Background.{RunNextDeploymentWorker, TenantJob}

  @impl true
  def enqueue do
    case %{} |> TenantJob.put_tenant() |> RunNextDeploymentWorker.new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, {:deployment_dispatch, reason}}
    end
  end
end
