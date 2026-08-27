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
    deployment_id = Map.get(input, :deployment_id)
    message_id = Map.get(input, :message_id)
    now = DateTime.truncate(deps.clock.now(), :microsecond)

    with {:ok, deployment} <-
           deps.repository.get_runner_deployment(deployment_id, runner_id),
         true <- valid_identifier?(message_id) do
      if deployment.idempotency_token == Map.get(input, :idempotency_token) do
        project_or_replay(deployment, input, message_id, now, runner_id, correlation_id, deps)
      else
        {:error, :stale_deployment_attempt}
      end
    else
      false -> {:error, :invalid_message_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp project_or_replay(deployment, input, message_id, now, runner_id, correlation_id, deps) do
    case deps.repository.find_event(deployment.id, message_id) do
      {:ok, event} ->
        replay(event, deployment, input)

      {:error, :not_found} ->
        project(deployment, input, message_id, now, runner_id, correlation_id, deps)
    end
  end

  defp project(deployment, input, message_id, now, runner_id, correlation_id, deps) do
    previous = deployment.status

    with {:ok, projected} <-
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
             %{
               runner_id: runner_id,
               message_id: message_id,
               correlation_id: correlation_id
             }
           ) do
      {:ok, view(projected)}
    end
  end

  defp replay(event, deployment, input) do
    if event.sequence == Map.get(input, :sequence) and
         event.status == to_string(Map.get(input, :status)) and
         event.reason == Map.get(input, :reason) do
      {:ok, view(deployment)}
    else
      {:error, :message_id_conflict}
    end
  end

  defp valid_identifier?(value), do: is_binary(value) and value != ""

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
