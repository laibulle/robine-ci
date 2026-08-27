defmodule Robine.Deployments.UseCases.GetRepositoryOverview do
  @moduledoc "Reads native deployment environments and retained deployment history."

  alias Robine.Deployments.Dependencies
  alias Robine.ExecutionContext

  def call(%{repository_id: repository_id}, %ExecutionContext{
        capabilities: capabilities,
        dependencies: %{deployments: %Dependencies{} = deps}
      })
      when is_binary(repository_id) do
    if Enum.any?([:ci_read, :ci_run, :ci_manage], &MapSet.member?(capabilities, &1)) do
      with {:ok, environments} <- deps.repository.list_environments(repository_id),
           {:ok, deployments} <- deps.repository.list_deployments(repository_id) do
        {:ok,
         %{
           environments: Enum.map(environments, &Map.from_struct/1),
           deployments: Enum.map(deployments, &deployment_view/1)
         }}
      end
    else
      {:error, :forbidden}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp deployment_view(deployment) do
    deployment
    |> Map.from_struct()
    |> Map.update!(:artifact, &Map.from_struct/1)
  end
end
