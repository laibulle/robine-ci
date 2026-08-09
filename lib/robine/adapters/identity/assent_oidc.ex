defmodule Robine.Adapters.Identity.AssentOIDC do
  @moduledoc false
  @behaviour Robine.Identities.Ports.OIDC

  @impl true
  def authorize_url(config) do
    config
    |> secure_oauth_config()
    |> Keyword.put(:nonce, random_nonce())
    |> Assent.Strategy.OIDC.authorize_url()
  end

  @impl true
  def callback(config, params) do
    case config |> secure_oauth_config() |> Assent.Strategy.OIDC.callback(params) do
      {:ok, %{user: claims}} -> {:ok, %{claims: claims}}
      {:error, reason} -> {:error, {:oidc, reason}}
    end
  end

  defp secure_oauth_config(config),
    do:
      config
      |> Keyword.put(:code_verifier, true)
      |> Keyword.put(:state, true)

  defp random_nonce do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
