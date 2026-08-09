defmodule Robine.Adapters.SourceControl.GitHubSignatureVerifier do
  @moduledoc false
  @behaviour Robine.Repositories.Ports.SignatureVerifier

  @impl true
  def verify(body, signature) when is_binary(body) and is_binary(signature) do
    with {:ok, secret} <- Robine.Adapters.SourceControl.GitHubCredentials.fetch(:webhook_secret),
         expected =
           "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)),
         true <- byte_size(expected) == byte_size(signature),
         true <- Plug.Crypto.secure_compare(expected, signature) do
      :ok
    else
      {:error, _reason} -> {:error, :webhook_secret_unavailable}
      _ -> {:error, :invalid_signature}
    end
  end
end
