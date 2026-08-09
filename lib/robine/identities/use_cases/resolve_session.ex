defmodule Robine.Identities.UseCases.ResolveSession do
  @moduledoc "Resolves a non-expired, non-revoked opaque session to its actor."
  alias Robine.ExecutionContext
  alias Robine.Identities.Dependencies

  def call(%{token: token}, %ExecutionContext{dependencies: %{identities: %Dependencies{} = deps}})
      when is_binary(token) do
    deps.repository.get_session(:crypto.hash(:sha256, token), deps.clock.now())
  end

  def call(_input, %ExecutionContext{}), do: {:error, :invalid_session}
end
