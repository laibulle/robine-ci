defmodule Robine.Adapters.System.IdGenerator do
  @moduledoc false
  @behaviour Robine.Pipelines.Ports.IdGenerator

  @impl true
  def generate, do: Ecto.UUID.generate()
end
