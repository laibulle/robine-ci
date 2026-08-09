defmodule Robine.Runners.UseCases.Heartbeat do
  @moduledoc "Records liveness for an authenticated, negotiated runner session."

  alias Robine.ExecutionContext
  alias Robine.Runners.Dependencies

  def call(%{protocol_version: version}, %ExecutionContext{
        actor: %{id: runner_id, role: :runner},
        dependencies: %{runners: %Dependencies{} = deps}
      })
      when is_integer(version) and version > 0 do
    now = deps.clock.now()

    case deps.registry.heartbeat(runner_id, version, now) do
      :ok -> {:ok, %{server_time: now}}
      {:error, reason} -> {:error, reason}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :unauthorized}
end
