defmodule Robine.Operations.Ports.Retention do
  @moduledoc "Retention and garbage-collection capability."
  @callback prune(DateTime.t(), keyword(), module()) :: {:ok, map()} | {:error, term()}
end
