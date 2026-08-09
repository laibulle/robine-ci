defmodule Robine.Adapters.Identity.AssentOIDC do
  @moduledoc false
  @behaviour Robine.Identities.Ports.OIDC

  @impl true
  def authorize_url(config) do
    config |> secure_config() |> Assent.Strategy.OIDC.authorize_url()
  end

  @impl true
  def callback(config, params) do
    case config |> secure_config() |> Assent.Strategy.OIDC.callback(params) do
      {:ok, %{user: claims}} -> {:ok, %{claims: claims}}
      {:error, reason} -> {:error, {:oidc, reason}}
    end
  end

  defp secure_config(config),
    do:
      config
      |> Keyword.put(:code_verifier, true)
      |> Keyword.put(:state, true)
      |> Keyword.put(:nonce, true)
end
