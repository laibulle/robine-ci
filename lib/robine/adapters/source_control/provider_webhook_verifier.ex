defmodule Robine.Adapters.SourceControl.ProviderWebhookVerifier do
  @moduledoc false
  @behaviour Robine.Repositories.Ports.WebhookVerifier

  alias Robine.Adapters.SourceControl.{GitHubSignatureVerifier, ProviderCredentials}

  @impl true
  def verify(:github, body, signature), do: GitHubSignatureVerifier.verify(body, signature)

  def verify(:gitlab, _body, token) when is_binary(token) do
    with {:ok, expected} <- ProviderCredentials.fetch(:gitlab, :webhook_secret),
         true <- byte_size(expected) == byte_size(token),
         true <- Plug.Crypto.secure_compare(expected, token) do
      :ok
    else
      {:error, _reason} -> {:error, :webhook_secret_unavailable}
      _invalid -> {:error, :invalid_signature}
    end
  end

  def verify(:forgejo, body, signature) when is_binary(body) and is_binary(signature) do
    with {:ok, secret} <- ProviderCredentials.fetch(:forgejo, :webhook_secret),
         expected <- :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower),
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, signature),
         true <- Plug.Crypto.secure_compare(expected, signature) do
      :ok
    else
      {:error, _reason} -> {:error, :webhook_secret_unavailable}
      _invalid -> {:error, :invalid_signature}
    end
  end

  def verify(_provider, _body, _authentication), do: {:error, :invalid_signature}
end
