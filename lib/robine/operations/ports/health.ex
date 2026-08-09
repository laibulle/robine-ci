defmodule Robine.Operations.Ports.Health do
  @moduledoc "Instance dependency health boundary."
  @callback check() :: {:ok, map()} | {:error, term()}
end
