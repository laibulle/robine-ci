defmodule Robine.Deployments.UseCases.RecordRunnerEvent do
  @moduledoc "Projects one ordered deployment phase event from an authenticated runner."

  alias Robine.Deployments.Dependencies
  alias Robine.Deployments.Domain.Deployment
  alias Robine.ExecutionContext

  def call(input, %ExecutionContext{
        actor: %{id: runner_id, role: :runner},
        correlation_id: correlation_id,
        dependencies: %{deployments: %Dependencies{} = deps}
      }) do
    now = DateTime.truncate(deps.clock.now(), :microsecond)

    with {:ok, deployment} <- deps.repository.get_deployment(Map.get(input, :deployment_id)),
         previous = deployment.status,
         {:ok, projected} <-
           Deployment.record_event(
             deployment,
             Map.get(input, :sequence),
             normalize_status(Map.get(input, :status)),
             Map.get(input, :reason),
             now
           ),
         :ok <-
           deps.repository.record_event(
             projected,
             previous,
             Map.get(input, :reason),
             now,
             %{runner_id: runner_id, correlation_id: correlation_id}
           ) do
      {:ok, view(projected)}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    Enum.find(
      [
        :preparing,
        :converging_services,
        :migrating,
        :activating,
        :verifying,
        :succeeded,
        :failed,
        :cancelled,
        :verification_failed
      ],
      &(Atom.to_string(&1) == status),
      :invalid
    )
  end

  defp normalize_status(_status), do: :invalid

  defp view(deployment),
    do: deployment |> Map.from_struct() |> Map.update!(:artifact, &Map.from_struct/1)
end
