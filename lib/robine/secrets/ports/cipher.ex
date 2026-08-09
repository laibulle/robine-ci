defmodule Robine.Secrets.Ports.Cipher do
  @moduledoc "Authenticated encryption capability for secret values."
  @callback encrypt(binary(), binary()) ::
              {:ok,
               %{ciphertext: binary(), nonce: binary(), tag: binary(), key_version: pos_integer()}}
              | {:error, term()}
  @callback decrypt(map(), binary()) :: {:ok, binary()} | {:error, term()}
  @callback current_version() :: {:ok, pos_integer()} | {:error, term()}
end
