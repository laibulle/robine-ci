defmodule Robine.Repositories.UseCases.FetchSource do
  @moduledoc "Fetches validated source files for one trusted repository at an exact commit SHA."
  alias Robine.ExecutionContext
  alias Robine.Repositories.Dependencies

  def call(%{repository_id: repository_id, commit_sha: sha}, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{repositories: %Dependencies{} = deps}
      })
      when is_binary(repository_id) and is_binary(sha) do
    with true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
         {:ok, repository} <- deps.repository.get_by_id(repository_id),
         true <- repository.trusted,
         {:ok, files} <- deps.github.source_files(repository, sha) do
      {:ok, %{repository_id: repository_id, commit_sha: sha, files: files}}
    else
      false -> {:error, :untrusted_or_invalid_source}
      error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
