defmodule Robine.Identities.UseCases.StartOIDC do
  @moduledoc "Starts OIDC Authorization Code flow with PKCE, state, and nonce."
  alias Robine.ExecutionContext
  alias Robine.Identities.Dependencies

  def call(_input, %ExecutionContext{dependencies: %{identities: %Dependencies{oidc_config: nil}}}),
      do: {:error, :oidc_not_configured}

  def call(_input, %ExecutionContext{dependencies: %{identities: %Dependencies{} = deps}}),
    do: deps.oidc.authorize_url(deps.oidc_config)
end
