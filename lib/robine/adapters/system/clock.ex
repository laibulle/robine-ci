defmodule Robine.Adapters.System.Clock do
  @moduledoc false
  @behaviour Robine.Pipelines.Ports.Clock

  @impl true
  def now, do: DateTime.utc_now()
end
