defmodule Robine.Operations.Ports.Health do
  @moduledoc "Instance dependency health boundary."
  @callback check(module()) :: {:ok, map()} | {:error, term()}
end
