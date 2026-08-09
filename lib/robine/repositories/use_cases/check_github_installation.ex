defmodule Robine.Repositories.UseCases.CheckGitHubInstallation do
  @moduledoc "Reports the effective least-privilege permissions for one trusted repository."

  alias Robine.ExecutionContext
  alias Robine.Repositories.Dependencies
  alias Robine.Repositories.Domain.GitHubPermissionPolicy

  @spec call(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  def call(%{repository_id: repository_id}, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{repositories: %Dependencies{} = dependencies}
      })
      when role in [:administrator, :maintainer] and is_binary(repository_id) do
    with {:ok, repository} <- dependencies.repository.get_by_id(repository_id),
         {:ok, permissions} <- dependencies.github.installation_permissions(repository) do
      {:ok, GitHubPermissionPolicy.evaluate(permissions)}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
