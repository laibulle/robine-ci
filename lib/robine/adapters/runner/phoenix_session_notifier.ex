defmodule Robine.Adapters.Runner.PhoenixSessionNotifier do
  @moduledoc false
  @behaviour Robine.Runners.Ports.SessionNotifier

  @impl true
  def runner_revoked(runner_id) do
    Robine.Runtime.Events.broadcast("runner:#{runner_id}", {:runner_revoked, runner_id})
  end
end
