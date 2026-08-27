defmodule Robine.Deployments.UseCases.RetryVerification do
  @moduledoc "Returns a verification-failed deployment to its bounded verification phase."

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
         :ok <- retryable?(deployment),
         {:ok, projected} <-
           Deployment.record_event(
             deployment,
             deployment.event_sequence + 1,
             :verifying,
             nil,
             now
           ),
         :ok <-
           deps.repository.record_event(projected, :verification_failed, nil, now, %{
             actor_id: actor_id,
             message_id: deps.id_generator.generate(),
             correlation_id: correlation_id
           }) do
      {:ok, view(projected)}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp retryable?(%Deployment{status: :verification_failed}), do: :ok
  defp retryable?(%Deployment{}), do: {:error, :verification_not_retryable}

  defp view(deployment),
    do: deployment |> Map.from_struct() |> Map.update!(:artifact, &Map.from_struct/1)
end
