defmodule Robine.Runners.Ports.TokenGenerator do
  @moduledoc "High-entropy opaque token generation capability."
  @callback generate(String.t()) :: String.t()
end
