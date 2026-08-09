defmodule Robine.TestSupport.RestartableEndpoint do
  @moduledoc false

  use GenServer

  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options)

  def port(endpoint), do: GenServer.call(endpoint, :port)
  def restart(endpoint), do: GenServer.call(endpoint, :restart, 10_000)

  @impl true
  def init(_options) do
    with {:ok, port} <- available_port(),
         {:ok, server} <- start_server(port) do
      {:ok, %{port: port, server: server}}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:restart, _from, state) do
    :ok = Supervisor.stop(state.server, :normal, 5_000)

    case start_server(state.port) do
      {:ok, server} -> {:reply, :ok, %{state | server: server}}
      {:error, reason} -> {:stop, reason, {:error, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.server), do: Supervisor.stop(state.server, :normal, 5_000)
    :ok
  end

  defp start_server(port) do
    Bandit.start_link(
      plug: RobineWeb.Endpoint,
      ip: {127, 0, 0, 1},
      port: port,
      startup_log: false
    )
  end

  defp available_port do
    with {:ok, socket} <- :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false]),
         {:ok, {_address, port}} <- :inet.sockname(socket),
         :ok <- :gen_tcp.close(socket) do
      {:ok, port}
    end
  end
end
