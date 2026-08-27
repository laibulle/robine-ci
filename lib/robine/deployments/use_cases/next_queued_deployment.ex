defmodule Robine.Deployments.UseCases.NextQueuedDeployment do
  @moduledoc "Reads the oldest unassigned deployment for bounded dispatcher coordination."

  alias Robine.Deployments.Dependencies
  alias Robine.ExecutionContext

  def call(_input, %ExecutionContext{
        capabilities: capabilities,
        dependencies: %{deployments: %Dependencies{} = deps}
      }) do
    if MapSet.member?(capabilities, :ci_manage) do
      with {:ok, deployment} <- deps.repository.next_queued() do
        {:ok,
         %{
           id: deployment.id,
           runner_labels: deployment.environment_snapshot.runner_labels,
           requested_at: deployment.requested_at
         }}
      end
    else
      {:error, :forbidden}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
