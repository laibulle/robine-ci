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
  def decrypt(
        %{ciphertext: ciphertext, nonce: nonce, tag: tag, key_version: version},
        aad
      )
      when is_binary(ciphertext) and is_binary(nonce) and byte_size(nonce) == 12 and
             is_binary(tag) and byte_size(tag) == 16 and is_integer(version) and version > 0 and
             is_binary(aad) do
    case key(version) do
      {:ok, key} ->
        case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, aad, tag, false) do
          :error -> decryption_error(:authentication_failed)
          plaintext -> {:ok, plaintext}
        end

      {:error, reason} ->
        decryption_error(reason)
    end
  end

  def decrypt(_encrypted, _aad), do: decryption_error(:invalid_ciphertext)

  @spec validate_configuration!() :: :ok
  def validate_configuration! do
    case current_key() do
      {:ok, _version, _key} ->
        :ok

      {:error, :key_unavailable} ->
        raise "Robine secret encryption key is unavailable; set ROBINE_SECRET_KEY to a base64-encoded 32-byte key"
    end
  end

  @impl true
  def current_version do
    case current_key() do
      {:ok, version, _key} -> {:ok, version}
      {:error, reason} -> {:error, reason}
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

  defp decryption_error(reason) do
    :telemetry.execute(
      [:robine, :secrets, :decryption_failure],
      %{count: 1},
      %{reason: reason}
    )

    {:error, reason}
  end
end
