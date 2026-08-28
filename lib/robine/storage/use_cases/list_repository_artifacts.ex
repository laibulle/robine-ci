defmodule Robine.Storage.UseCases.ListRepositoryArtifacts do
  @moduledoc "Lists every retained artifact for an authorized repository user."

  alias Robine.ExecutionContext
  alias Robine.Storage.ArtifactUpload
  alias Robine.Storage.Dependencies

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @spec call(map(), ExecutionContext.t()) ::
          {:ok, [Robine.Storage.Contracts.ArtifactMetadata.t()]} | {:error, term()}
  def call(%{repository_id: repository_id}, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{storage: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer, :viewer] do
    if valid_uuid?(repository_id) and deps.repository.repository_exists?(repository_id) do
      now = deps.clock.now()

      artifacts =
        repository_id
        |> deps.repository.list_repository_artifacts()
        |> Enum.filter(&(DateTime.compare(&1.expires_at, now) == :gt))
        |> Enum.map(&ArtifactUpload.metadata/1)

      {:ok, artifacts}
    else
      {:error, :repository_not_found}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp valid_uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)
end
