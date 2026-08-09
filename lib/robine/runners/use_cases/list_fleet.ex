defmodule Robine.Runners.UseCases.ListFleet do
  @moduledoc "Lists the runner fleet with derived connectivity and capacity projections."

  alias Robine.ExecutionContext
  alias Robine.Runners.Dependencies

  def call(_input, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{runners: %Dependencies{} = deps}
      }) do
    deps.registry.list_fleet(deps.clock.now())
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
