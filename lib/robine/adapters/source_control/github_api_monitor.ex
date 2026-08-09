defmodule Robine.Adapters.SourceControl.GitHubApiMonitor do
  @moduledoc false
  use GenServer

  def start_link(_options), do: GenServer.start_link(__MODULE__, :not_observed, name: __MODULE__)

  def record(measurements, metadata) do
    if Process.whereis(__MODULE__),
      do: GenServer.cast(__MODULE__, {:record, measurements, metadata})

    :ok
  end

  def snapshot do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, :snapshot),
      else: :not_observed
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:record, measurements, metadata}, _state) do
    state = %{
      outcome: metadata.outcome,
      status: metadata.status,
      rate_limit_remaining: Map.get(measurements, :rate_limit_remaining),
      rate_limit_limit: Map.get(measurements, :rate_limit_limit),
      rate_limit_reset: Map.get(measurements, :rate_limit_reset),
      observed_at: DateTime.utc_now()
    }

    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}
end
