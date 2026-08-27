defmodule Robine.Deployments.Ports.Dispatcher do
  @moduledoc "Wakes durable deployment dispatch after a queued state is committed."

  @callback enqueue() :: :ok | {:error, term()}
end
