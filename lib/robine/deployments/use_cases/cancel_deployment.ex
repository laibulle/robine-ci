defmodule Robine.Deployments.UseCases.CancelDeployment do
  @moduledoc "Cancels a deployment without claiming reversal of remote effects."

  alias Robine.Deployments.Dependencies
  alias Robine.Deployments.Domain.Deployment
  alias Robine.ExecutionContext

  def call(%{deployment_id: deployment_id}, %ExecutionContext{
        actor: %{id: actor_id},
        capabilities: capabilities,
        correlation_id: correlation_id,
        dependencies: %{deployments: %Dependencies{} = deps}
      }) do
    if MapSet.member?(capabilities, :ci_run) or MapSet.member?(capabilities, :ci_manage) do
      now = DateTime.truncate(deps.clock.now(), :microsecond)

      with {:ok, deployment} <- deps.repository.get_deployment(deployment_id),
           true <-
             deployment.requester_id == actor_id or MapSet.member?(capabilities, :ci_manage),
           previous = deployment.status,
           {:ok, cancelled} <- Deployment.cancel(deployment, now),
           :ok <-
             deps.repository.update_deployment(cancelled, previous, %{
               actor_id: actor_id,
               correlation_id: correlation_id,
               action: "deployment.cancelled"
             }) do
        {:ok, view(cancelled)}
      else
        false -> {:error, :forbidden}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :forbidden}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp view(deployment),
    do: deployment |> Map.from_struct() |> Map.update!(:artifact, &Map.from_struct/1)
end
