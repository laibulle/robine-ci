defmodule Robine.ExecutionContext do
  @moduledoc """
  Request-scoped actor, correlation metadata, and explicitly assembled dependencies.

  Delivery adapters obtain contexts from `Robine.Runtime.Dependencies`. Unit tests
  may construct contexts with deterministic fake dependencies.
  """

  @enforce_keys [:actor, :correlation_id, :dependencies]
  defstruct [:actor, :correlation_id, :dependencies]

  @type actor :: %{required(:id) => String.t(), required(:role) => atom()}
  @type t :: %__MODULE__{
          actor: actor(),
          correlation_id: String.t(),
          dependencies: map()
        }

  @spec new(actor(), String.t(), map()) :: t()
  def new(actor, correlation_id, dependencies)
      when is_map(actor) and is_binary(correlation_id) and is_map(dependencies) do
    %__MODULE__{actor: actor, correlation_id: correlation_id, dependencies: dependencies}
  end
end
