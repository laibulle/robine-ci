defmodule Robine.Execution.Ports.Runner do
  @moduledoc "Execution capability for one normalized job specification."

  alias Robine.Execution.Contracts.{Result, Specification}

  @callback run(Specification.t()) :: {:ok, Result.t()} | {:error, term()}
end
