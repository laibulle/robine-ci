defmodule Robine.Deployments.UseCases.AssignDeployment do
  @moduledoc "Atomically assigns queued deployment work to a dedicated runner lease."

  alias Robine.Deployments.Dependencies
  alias Robine.Deployments.Domain.Deployment
  alias Robine.ExecutionContext

  def call(input, %ExecutionContext{
        actor: %{id: actor_id},
        capabilities: capabilities,
        correlation_id: correlation_id,
        dependencies: %{deployments: %Dependencies{} = deps}
      }) do
    if MapSet.member?(capabilities, :ci_manage) do
      lease_seconds = Map.get(input, :lease_seconds, 60)

      with true <- is_integer(lease_seconds) and lease_seconds in 30..300,
           {:ok, deployment} <- deps.repository.get_deployment(Map.get(input, :deployment_id)),
           now = DateTime.truncate(deps.clock.now(), :microsecond),
           {:ok, assigned} <-
             Deployment.assign(
               deployment,
               Map.get(input, :runner_id),
               deps.id_generator.generate(),
               deps.id_generator.generate(),
               now,
               DateTime.add(now, lease_seconds, :second)
             ),
           :ok <-
             deps.repository.update_deployment(assigned, :queued, %{
               actor_id: actor_id,
               correlation_id: correlation_id,
               action: "deployment.assigned"
             }) do
        {:ok, view(assigned)}
      else
        false -> {:error, :invalid_deployment_lease}
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
