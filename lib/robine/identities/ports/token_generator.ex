defmodule Robine.Identities.Ports.TokenGenerator do
  @moduledoc "High-entropy opaque API token generation capability."
  @callback generate(String.t()) :: String.t()
end
