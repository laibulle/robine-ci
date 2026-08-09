defmodule Robine.Transfers.Dependencies do
  @moduledoc false
  alias Robine.Transfers.Ports

  @enforce_keys [:archive]
  defstruct [:archive]

  @type t :: %__MODULE__{archive: module()}

  def validate!(%__MODULE__{} = dependencies) do
    Code.ensure_loaded!(dependencies.archive)

    unless Ports.Archive in (dependencies.archive.module_info(:attributes)[:behaviour] || []),
      do:
        raise(
          ArgumentError,
          "#{inspect(dependencies.archive)} must implement #{inspect(Ports.Archive)}"
        )

    :ok
  end
end
