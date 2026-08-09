defmodule Robine.Pipelines.Ports.Clock do
  @moduledoc "Clock capability for deterministic pipeline behavior."

  @callback now() :: DateTime.t()
end
