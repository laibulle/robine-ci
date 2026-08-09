defmodule Robine.Identities.UseCases.GetOIDCConfiguration do
  @moduledoc "Returns a secret-free OIDC configuration projection and optional discovery preflight."
  alias Robine.ExecutionContext
  alias Robine.Identities.Dependencies

  def call(input, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{identities: %Dependencies{} = deps}
      }) do
    case deps.oidc_config do
      nil -> {:ok, %{enabled: false, issuer: nil, redirect_uri: nil, preflight: :not_configured}}
      config -> configuration(config, deps, Map.get(input, :preflight, false))
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp configuration(config, _deps, false) do
    {:ok,
     %{
       enabled: true,
       issuer: config[:base_url],
       redirect_uri: config[:redirect_uri],
       preflight: :not_run
     }}
  end

  defp configuration(config, deps, true) do
    preflight =
      case deps.oidc.authorize_url(config) do
        {:ok, %{url: url}} -> {:ok, URI.parse(url).host}
        {:error, reason} -> {:error, reason}
      end

    {:ok,
     %{
       enabled: true,
       issuer: config[:base_url],
       redirect_uri: config[:redirect_uri],
       preflight: preflight
     }}
  end
end
