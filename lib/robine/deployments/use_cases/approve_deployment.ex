defmodule Robine.Deployments.UseCases.ApproveDeployment do
  @moduledoc "Approves a protected deployment without permitting requester self-approval."

  alias Robine.Deployments.Dependencies
  alias Robine.Deployments.Domain.Deployment
  alias Robine.ExecutionContext

  def call(%{deployment_id: deployment_id}, %ExecutionContext{
        actor: %{id: actor_id, role: :administrator},
        correlation_id: correlation_id,
        dependencies: %{deployments: %Dependencies{} = deps}
      }) do
    now = DateTime.truncate(deps.clock.now(), :microsecond)

    with {:ok, deployment} <- deps.repository.get_deployment(deployment_id),
         previous = deployment.status,
         {:ok, approved} <- Deployment.approve(deployment, actor_id, now),
         :ok <-
           deps.repository.update_deployment(approved, previous, %{
             actor_id: actor_id,
             correlation_id: correlation_id,
             action: "deployment.approved"
           }) do
      _ = deps.dispatcher.enqueue()
      {:ok, view(approved)}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp view(deployment),
    do: deployment |> Map.from_struct() |> Map.update!(:artifact, &Map.from_struct/1)
end
