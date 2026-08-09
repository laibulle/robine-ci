defmodule Robine.Repositories.UseCases.TrustGitHubRepository do
  @moduledoc "Trusts a repository only after matching it against live GitHub App access."

  alias Robine.ExecutionContext
  alias Robine.Repositories.UseCases.{DiscoverGitHubRepositories, RegisterGitHubRepository}

  def call(input, %ExecutionContext{actor: %{role: :administrator}} = context) do
    with {:ok, selected} <- selection(input),
         {:ok, available} <- DiscoverGitHubRepositories.call(%{}, context),
         repository when not is_nil(repository) <- Enum.find(available, &matches?(&1, selected)) do
      RegisterGitHubRepository.call(
        Map.take(repository, [:provider_id, :installation_id, :full_name]),
        context
      )
    else
      nil -> {:error, :repository_not_granted_to_github_app}
      {:error, _reason} = error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp selection(input) do
    with {provider_id, ""} <- Integer.parse(to_string(Map.get(input, :provider_id))),
         {installation_id, ""} <- Integer.parse(to_string(Map.get(input, :installation_id))),
         full_name when is_binary(full_name) and full_name != "" <- Map.get(input, :full_name) do
      {:ok, %{provider_id: provider_id, installation_id: installation_id, full_name: full_name}}
    else
      _ -> {:error, :invalid_repository_selection}
    end
  end

  defp matches?(repository, selected),
    do:
      repository.provider_id == selected.provider_id and
        repository.installation_id == selected.installation_id and
        repository.full_name == selected.full_name
end
