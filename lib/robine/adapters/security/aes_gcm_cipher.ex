defmodule Robine.Adapters.Security.AesGcmCipher do
  @moduledoc false
  @behaviour Robine.Secrets.Ports.Cipher

  @impl true
  def encrypt(plaintext, aad) when is_binary(plaintext) and is_binary(aad) do
    with {:ok, version, key} <- current_key() do
      nonce = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad, true)

      {:ok, %{ciphertext: ciphertext, nonce: nonce, tag: tag, key_version: version}}
    end
  end

  @impl true
  def decrypt(%{ciphertext: ciphertext, nonce: nonce, tag: tag, key_version: version}, aad) do
    with {:ok, key} <- key(version) do
      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, aad, tag, false) do
        :error -> {:error, :authentication_failed}
        plaintext -> {:ok, plaintext}
      end
    end
  end

  @spec validate_configuration!() :: :ok
  def validate_configuration! do
    case current_key() do
      {:ok, _version, _key} ->
        :ok

      {:error, :key_unavailable} ->
        raise "Robine secret encryption key is unavailable; set ROBINE_SECRET_KEY to a base64-encoded 32-byte key"
    end
  end

  defp current_key do
    with %{current_version: version} <- keyring(),
         {:ok, key} <- key(version),
         do: {:ok, version, key},
         else: (_ -> {:error, :key_unavailable})
  end

  defp key(version) do
    case keyring() do
      %{keys: %{^version => key}} when is_binary(key) and byte_size(key) == 32 -> {:ok, key}
      _ -> {:error, :key_unavailable}
    end
  end

  defp keyring do
    case Application.get_env(:robine, :secret_keyring, %{}) do
      configuration when is_list(configuration) -> Map.new(configuration)
      configuration when is_map(configuration) -> configuration
      _configuration -> %{}
    end
  end
end
