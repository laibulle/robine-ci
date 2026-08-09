defmodule Robine.Operations.Ports.Retention do
  @moduledoc "Retention and garbage-collection capability."
  @callback prune(DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()}
end
