defmodule Robine.Repositories.Ports.SignatureVerifier do
  @moduledoc "GitHub webhook signature verification capability."
  @callback verify(binary(), binary()) :: :ok | {:error, :invalid_signature | term()}
end
