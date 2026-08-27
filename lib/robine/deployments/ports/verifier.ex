defmodule Robine.Deployments.Ports.Verifier do
  @moduledoc "Checks bounded HTTP health and the exact deployed release version."

  @callback verify(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
end
