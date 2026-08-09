defmodule Robine.Runners.Ports.SessionNotifier do
  @moduledoc "Best-effort delivery of runner lifecycle changes after durable mutation."
  @callback runner_revoked(String.t()) :: :ok | {:error, term()}
end
