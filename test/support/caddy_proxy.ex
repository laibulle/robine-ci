defmodule Robine.TestSupport.CaddyProxy do
  @moduledoc false

  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  def url(proxy), do: GenServer.call(proxy, :url)

  @impl true
  def init(options) do
    executable = Keyword.fetch!(options, :executable)
    backend_port = Keyword.fetch!(options, :backend_port)

    with {:ok, proxy_port} <- available_port(),
         {:ok, directory} <- temporary_directory(),
         :ok <- write_config(directory, proxy_port, backend_port),
         {:ok, process} <- start_caddy(executable, directory),
         :ok <- await_listener(proxy_port) do
      {:ok,
       %{
         directory: directory,
         port: proxy_port,
         process: process
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:url, _from, state) do
    {:reply, "http://127.0.0.1:#{state.port}", state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = Exile.Process.kill(state.process, :sigterm)
    _ = Exile.Process.await_exit(state.process, 2_000)
    _ = File.rm_rf(state.directory)
    :ok
  end

  defp available_port do
    with {:ok, socket} <- :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false]),
         {:ok, {_address, port}} <- :inet.sockname(socket),
         :ok <- :gen_tcp.close(socket) do
      {:ok, port}
    end
  end

  defp temporary_directory do
    directory = Path.join(System.tmp_dir!(), "robine-caddy-#{Ecto.UUID.generate()}")

    case File.mkdir(directory) do
      :ok -> {:ok, directory}
      {:error, reason} -> {:error, {:temporary_directory, reason}}
    end
  end

  defp write_config(directory, proxy_port, backend_port) do
    config = """
    {
      admin off
      auto_https off
    }

    http://127.0.0.1:#{proxy_port} {
      reverse_proxy 127.0.0.1:#{backend_port}
    }
    """

    File.write(Path.join(directory, "Caddyfile"), config)
  end

  defp start_caddy(executable, directory) do
    Exile.Process.start_link(
      [
        executable,
        "run",
        "--config",
        Path.join(directory, "Caddyfile"),
        "--adapter",
        "caddyfile"
      ],
      stderr: :disable
    )
  end

  defp await_listener(port) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    connect_until_ready(port, deadline)
  end

  defp connect_until_ready(port, deadline) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 50) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> connect_until_ready(port, deadline)
          end
        else
          {:error, :caddy_start_timeout}
        end
    end
  end
end
