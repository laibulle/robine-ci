defmodule Robine.Publications.UseCases.GetRepositoryOverview do
  @moduledoc "Reads one repository's publication policy and release projection."
  alias Robine.ExecutionContext
  alias Robine.Publications.Dependencies

  def call(%{repository_id: repository_id}, %ExecutionContext{
        capabilities: capabilities,
        dependencies: %{publications: %Dependencies{} = deps}
      })
      when is_binary(repository_id) do
    if Enum.any?([:ci_read, :ci_run, :ci_manage], &MapSet.member?(capabilities, &1)) do
      with {:ok, policy} <- deps.repository.get_policy(repository_id),
           {:ok, publications} <- deps.repository.list_publications(repository_id) do
        {:ok, %{policy: policy && Map.from_struct(policy), publications: publications}}
      end
    else
      {:error, :forbidden}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
