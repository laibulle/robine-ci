defmodule Robine.Secrets.UseCases.ListSecrets do
  @moduledoc "Lists write-only secret metadata for a repository."
  alias Robine.ExecutionContext
  alias Robine.Secrets.Dependencies

  def call(%{repository_id: repository_id}, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{secrets: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer] and is_binary(repository_id) do
    deps.repository.list_metadata(repository_id)
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
