defmodule Robine.Execution.Ports.Runner do
  @moduledoc "Execution capability for one normalized job specification."

  alias Robine.Execution.Contracts.{Result, Specification}

  @callback run(Specification.t(), (map() -> term()), (-> boolean())) ::
              {:ok, Result.t()} | {:error, term()}
  @callback reconcile_resources([String.t()]) :: {:ok, map()} | {:error, term()}
end
