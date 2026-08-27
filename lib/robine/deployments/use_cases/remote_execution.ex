defmodule Robine.Deployments.UseCases.RemoteExecution do
  @moduledoc "Returns one assigned runner's bounded deployment document without secret values."

  alias Robine.Deployments.Dependencies
  alias Robine.ExecutionContext

  def call(%{deployment_id: deployment_id}, %ExecutionContext{
        actor: %{id: runner_id, role: :runner},
        dependencies: %{deployments: %Dependencies{} = deps}
      }) do
    with {:ok, deployment} <- deps.repository.get_runner_deployment(deployment_id, runner_id),
         true <- active?(deployment.status) do
      snapshot = stringify(deployment.environment_snapshot)

      {:ok,
       %{
         "deployment_id" => deployment.id,
         "attempt_id" => deployment.attempt_id,
         "idempotency_token" => deployment.idempotency_token,
         "repository_id" => deployment.repository_id,
         "kind" => Atom.to_string(deployment.kind),
         "artifact" => stringify(Map.from_struct(deployment.artifact)),
         "environment" => snapshot,
         "secret_names" => secret_names(snapshot),
         "lease_expires_at" => DateTime.to_iso8601(deployment.lease_expires_at)
       }}
    else
      false -> {:error, :deployment_not_active}
      {:error, reason} -> {:error, reason}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp active?(status),
    do: status in [:queued, :preparing, :converging_services, :migrating, :activating, :verifying]

  defp secret_names(%{"services" => services}) do
    services
    |> Enum.flat_map(fn service -> Map.values(Map.get(service, "secret_environment", %{})) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp secret_names(_snapshot), do: []

  defp stringify(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
