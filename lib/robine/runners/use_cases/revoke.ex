defmodule Robine.Runners.UseCases.Revoke do
  @moduledoc "Revokes a runner and all of its credentials immediately."

  alias Robine.ExecutionContext
  alias Robine.Runners.Dependencies

  def call(%{runner_id: runner_id}, %ExecutionContext{
        actor: %{id: actor_id, role: :administrator},
        correlation_id: correlation_id,
        dependencies: %{runners: %Dependencies{} = deps}
      })
      when is_binary(runner_id) do
    with :ok <-
           deps.registry.revoke(runner_id, deps.clock.now(), %{
             actor_id: actor_id,
             correlation_id: correlation_id
           }),
         :ok <- deps.session_notifier.runner_revoked(runner_id) do
      :ok
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
