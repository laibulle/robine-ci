defmodule Robine.Repositories.UseCases.DiscoverGitHubRepositories do
  @moduledoc "Lists repositories currently granted to the configured GitHub App."

  alias Robine.ExecutionContext
  alias Robine.Repositories.Dependencies

  def call(_input, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{repositories: %Dependencies{} = deps}
      }) do
    with {:ok, repositories} <- deps.github.available_repositories(),
         true <- Enum.all?(repositories, &valid?/1) do
      {:ok, Enum.sort_by(repositories, &String.downcase(&1.full_name))}
    else
      false -> {:error, :invalid_github_repository_discovery}
      {:error, _reason} = error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp valid?(repository) do
    is_integer(repository.provider_id) and is_integer(repository.installation_id) and
      is_binary(repository.full_name) and repository.full_name != "" and
      is_boolean(repository.private)
  end
end
