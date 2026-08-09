defmodule Robine.Identities.Ports.Passwords do
  @moduledoc "Password hashing boundary."
  @callback hash(String.t()) :: String.t()
  @callback verify(String.t(), String.t()) :: boolean()
  @callback dummy_verify() :: false
end
