defmodule Robine.Runners.UseCases.SelectAvailableRunner do
  @moduledoc "Selects an online Docker-capable runner candidate for atomic job claiming."

  alias Robine.ExecutionContext
  alias Robine.Runners.Dependencies

  def call(_input, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{runners: %Dependencies{} = deps}
      }) do
    deps.registry.next_available(deps.clock.now())
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
