defmodule Robine.Identities.UseCases.ChangeUserRole do
  @moduledoc "Changes a role while preserving at least one usable administrator."
  alias Robine.ExecutionContext
  alias Robine.Identities.Dependencies
  alias Robine.Identities.Domain.User

  def call(%{user_id: user_id, role: role}, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{identities: %Dependencies{} = deps}
      })
      when is_binary(user_id) and role in [:administrator, :maintainer, :viewer] do
    with {:ok, user} <- deps.repository.get_user(user_id),
         :ok <- preserve_admin(user, role, deps),
         :ok <- deps.repository.update_role(user_id, role) do
      {:ok, %{id: user.id, email: user.email, role: role}}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp preserve_admin(%User{role: :administrator}, role, deps) when role != :administrator do
    if deps.repository.count_usable_administrators() > 1,
      do: :ok,
      else: {:error, :last_administrator}
  end

  defp preserve_admin(_user, _role, _deps), do: :ok
end
