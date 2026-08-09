defmodule Robine.Identities.Ports.OIDC do
  @moduledoc "OpenID Connect protocol boundary."
  @callback authorize_url(keyword()) ::
              {:ok, %{url: String.t(), session_params: map()}} | {:error, term()}
  @callback callback(keyword(), map()) :: {:ok, %{claims: map()}} | {:error, term()}
end
