defmodule Robine.Adapters.Runner.PhoenixSessionNotifier do
  @moduledoc false
  @behaviour Robine.Runners.Ports.SessionNotifier

  @impl true
  def runner_revoked(runner_id) do
    Phoenix.PubSub.broadcast(Robine.PubSub, "runner:#{runner_id}", {:runner_revoked, runner_id})
  end
end
