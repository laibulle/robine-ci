defmodule Robine.Repositories.UseCases.CheckSourceControlConnection do
  @moduledoc "Checks authenticated repository access for a non-GitHub source-control provider."

  alias Robine.ExecutionContext
  alias Robine.Repositories.Dependencies

  @spec call(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  def call(%{repository_id: repository_id}, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{repositories: %Dependencies{} = dependencies}
      })
      when role in [:administrator, :maintainer] and is_binary(repository_id) do
    with {:ok, repository} <- dependencies.repository.get_by_id(repository_id),
         true <- repository.provider in [:gitlab, :forgejo],
         {:ok, permissions} <-
           dependencies.source_control.installation_permissions(repository),
         true <- is_map(permissions) do
      {:ok, %{status: :ok, provider: repository.provider}}
    else
      false -> {:error, :invalid_source_control_connection}
      {:error, _reason} = error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
