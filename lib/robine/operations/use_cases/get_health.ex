defmodule Robine.Operations.UseCases.GetHealth do
  @moduledoc "Returns a secret-free operational health projection."
  alias Robine.ExecutionContext
  alias Robine.Operations.Dependencies

  def call(_input, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{operations: %Dependencies{} = deps}
      }),
      do: deps.health.check(deps.blob_store)

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
