defmodule Robine.Runners.UseCases.UpdateRunner do
  @moduledoc "Renames, labels, enables, or drains one runner with an audit trail."

  alias Robine.ExecutionContext
  alias Robine.Runners.Dependencies
  alias Robine.Runners.Domain.Runner

  def call(%{runner_id: runner_id} = input, %ExecutionContext{
        actor: %{id: actor_id, role: :administrator},
        correlation_id: correlation_id,
        dependencies: %{runners: %Dependencies{} = deps}
      })
      when is_binary(runner_id) do
    changes = Map.take(input, [:name, :labels, :admin_state])

    with true <- map_size(changes) > 0,
         {:ok, runner} <- deps.registry.get(runner_id),
         {:ok, configured} <- Runner.configure(runner, changes, deps.clock.now()),
         :ok <-
           deps.registry.update_configuration(configured, %{
             actor_id: actor_id,
             correlation_id: correlation_id,
             before: Map.take(Map.from_struct(runner), [:name, :labels, :admin_state]),
             after: Map.take(Map.from_struct(configured), [:name, :labels, :admin_state])
           }) do
      {:ok, Map.take(Map.from_struct(configured), [:id, :name, :labels, :admin_state])}
    else
      false -> {:error, :empty_runner_update}
      {:error, _reason} = error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
