defmodule Robine.Adapters.Security.HmacRunnerCredentials do
  @moduledoc false
  @behaviour Robine.Runners.Ports.CredentialDigester

  @impl true
  def digest(secret) when is_binary(secret) do
    :crypto.mac(:hmac, :sha256, signing_key(), secret)
  end

  @impl true
  def verify(secret, expected_digest)
      when is_binary(secret) and is_binary(expected_digest) and byte_size(expected_digest) == 32 do
    Plug.Crypto.secure_compare(digest(secret), expected_digest)
  end

  def verify(_secret, _expected_digest), do: false

  defp signing_key do
    secret_key_base =
      :robine
      |> Application.fetch_env!(RobineWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    :crypto.mac(:hmac, :sha256, secret_key_base, "robine:runner-credential:v1")
  end
end
