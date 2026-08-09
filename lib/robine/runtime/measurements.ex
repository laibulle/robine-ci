defmodule Robine.Runtime.Measurements do
  @moduledoc "Composition-root entry points for periodic infrastructure measurements."

  @spec storage_pressure() :: :ok
  def storage_pressure, do: Robine.Adapters.System.DiskAdmission.measure()
end
