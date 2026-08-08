defmodule Robine.Pipelines.Ports.IdGenerator do
  @moduledoc "Opaque ID generation capability."

  @callback generate() :: String.t()
end
