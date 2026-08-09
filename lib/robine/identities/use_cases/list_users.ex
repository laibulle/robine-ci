defmodule Robine.Identities.UseCases.ListUsers do
  @moduledoc "Lists non-sensitive user metadata for identity administration."
  alias Robine.ExecutionContext
  alias Robine.Identities.Dependencies

  def call(_input, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{identities: %Dependencies{} = deps}
      }) do
    with {:ok, users} <- deps.repository.list_users() do
      {:ok,
       Enum.map(
         users,
         &Map.take(Map.from_struct(&1), [:id, :email, :role, :disabled, :inserted_at])
       )}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
