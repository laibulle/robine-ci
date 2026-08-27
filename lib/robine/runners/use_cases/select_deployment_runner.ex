defmodule Robine.Runners.UseCases.SelectDeploymentRunner do
  @moduledoc "Selects dedicated online deployment capacity matching exact environment labels."

  alias Robine.ExecutionContext
  alias Robine.Runners.Dependencies

  def call(%{labels: labels}, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{runners: %Dependencies{} = deps}
      })
      when is_list(labels) do
    deps.registry.next_deployment_available(labels, deps.clock.now())
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
