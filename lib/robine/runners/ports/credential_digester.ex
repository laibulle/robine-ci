defmodule Robine.Runners.Ports.CredentialDigester do
  @moduledoc "One-way runner secret digest and constant-time verification capability."
  @callback digest(String.t()) :: binary()
  @callback verify(String.t(), binary()) :: boolean()
end
