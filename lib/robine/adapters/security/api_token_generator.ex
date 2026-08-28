defmodule Robine.Adapters.Security.ApiTokenGenerator do
  @moduledoc false
  @behaviour Robine.Identities.Ports.TokenGenerator

  @impl true
  def generate(prefix) when is_binary(prefix) do
    prefix <> "_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
  end
end
