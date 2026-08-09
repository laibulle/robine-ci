defmodule RobineWeb.LoginRateLimiter do
  @moduledoc false
  use GenServer
  @limit 10
  @window_ms 60_000

  def start_link(_options), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def allowed?(key),
    do: GenServer.call(__MODULE__, {:allowed, key, System.monotonic_time(:millisecond)})

  @impl true
  def init(state), do: {:ok, state}
  @impl true
  def handle_call({:allowed, key, now}, _from, state) do
    {started, count} = Map.get(state, key, {now, 0})
    {started, count} = if now - started >= @window_ms, do: {now, 0}, else: {started, count}
    allowed = count < @limit
    state = Map.put(state, key, {started, count + 1})
    {:reply, allowed, prune(state, now)}
  end

  defp prune(state, now),
    do: Map.reject(state, fn {_key, {started, _count}} -> now - started >= @window_ms * 2 end)
end
