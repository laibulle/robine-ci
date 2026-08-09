defmodule Robine.Repositories.UseCases.ListRepositories do
  @moduledoc "Lists trusted source-control repositories without credentials."
  alias Robine.ExecutionContext
  alias Robine.Repositories.Dependencies

  def call(_input, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{repositories: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer, :viewer] do
    with {:ok, repositories} <- deps.repository.list() do
      {:ok,
       Enum.map(repositories, fn repository ->
         Map.take(Map.from_struct(repository), [
           :id,
           :owner,
           :name,
           :full_name,
           :trusted,
           :inserted_at
         ])
       end)}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
