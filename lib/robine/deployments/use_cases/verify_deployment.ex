defmodule Robine.Deployments.UseCases.VerifyDeployment do
  @moduledoc "Verifies health and exact release version before projecting deployment success."

  alias Robine.Deployments.Dependencies
  alias Robine.Deployments.Domain.Deployment
  alias Robine.ExecutionContext

  def call(%{deployment_id: deployment_id}, %ExecutionContext{
        actor: %{id: actor_id},
        capabilities: capabilities,
        correlation_id: correlation_id,
        dependencies: %{deployments: %Dependencies{} = deps}
      }) do
    if MapSet.member?(capabilities, :ci_manage) do
      now = DateTime.truncate(deps.clock.now(), :microsecond)

      with {:ok, deployment} <- deps.repository.get_deployment(deployment_id),
           :ok <- verifying?(deployment),
           result <-
             deps.verifier.verify(
               deployment.environment_snapshot.verification,
               deployment.artifact.tag,
               []
             ),
           {status, reason} <- verification_projection(result),
           {:ok, projected} <-
             Deployment.record_event(
               deployment,
               deployment.event_sequence + 1,
               status,
               reason,
               now
             ),
           :ok <-
             deps.repository.record_event(projected, :verifying, reason, now, %{
               actor_id: actor_id,
               message_id: deps.id_generator.generate(),
               correlation_id: correlation_id
             }) do
        {:ok, view(projected)}
      end
    else
      {:error, :forbidden}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp verifying?(%Deployment{status: :verifying}), do: :ok
  defp verifying?(%Deployment{}), do: {:error, :deployment_not_verifying}

  defp verification_projection({:ok, _result}), do: {:succeeded, nil}
  defp verification_projection({:error, reason}), do: {:verification_failed, safe_reason(reason)}

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "verification_failed"

  defp view(deployment),
    do: deployment |> Map.from_struct() |> Map.update!(:artifact, &Map.from_struct/1)
end
