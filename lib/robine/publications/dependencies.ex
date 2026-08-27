defmodule Robine.Publications.Dependencies do
  @moduledoc false
  alias Robine.Publications.Ports

  @enforce_keys [:repository, :clock, :id_generator]
  defstruct [:repository, :clock, :id_generator]

  @type t :: %__MODULE__{repository: module(), clock: module(), id_generator: module()}

  @spec validate!(t()) :: :ok
  def validate!(%__MODULE__{} = dependencies) do
    Code.ensure_loaded!(dependencies.repository)

    unless Ports.Repository in (dependencies.repository.module_info(:attributes)[:behaviour] || []) do
      raise ArgumentError,
            "#{inspect(dependencies.repository)} must implement #{inspect(Ports.Repository)}"
    end

    :ok
  end
end
