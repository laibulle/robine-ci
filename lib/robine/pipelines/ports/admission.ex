defmodule Robine.Pipelines.Ports.Admission do
  @moduledoc "Host-capacity admission gate evaluated before a job is claimed."
  @callback check() :: :ok | {:error, :disk_pressure | term()}
end
