defmodule Robine.Identities.UseCases.RevokeSession do
  @moduledoc "Revokes an opaque session token."
  alias Robine.ExecutionContext
  alias Robine.Identities.Dependencies

  def call(%{token: token}, %ExecutionContext{dependencies: %{identities: %Dependencies{} = deps}})
      when is_binary(token) do
    deps.repository.revoke_session(:crypto.hash(:sha256, token), deps.clock.now())
  end

  def call(_input, %ExecutionContext{}), do: {:error, :invalid_session}
end
