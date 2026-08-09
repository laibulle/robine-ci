defmodule Robine.Pipelines.Ports.UnitOfWork do
  @moduledoc "Atomic persistence boundary for one pipeline use case."

  @callback transaction((-> {:ok, result} | {:error, reason})) ::
              {:ok, result} | {:error, reason}
            when result: term(), reason: term()
  @callback lock(String.t()) :: :ok | {:error, term()}
end
