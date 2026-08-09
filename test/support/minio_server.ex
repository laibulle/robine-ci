defmodule Robine.TestSupport.MinioServer do
  @moduledoc false

  use GenServer

  alias Robine.TestSupport.DockerEndpoint

  @image "minio/minio:RELEASE.2025-09-07T16-13-09Z"

  def image, do: @image
  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options)
  def endpoint(server), do: GenServer.call(server, :endpoint)

  @impl true
  def init(_options) do
    Process.flag(:trap_exit, true)

    with {:ok, port} <- available_port(),
         name = "robine-minio-#{Ecto.UUID.generate()}",
         {container_id, 0} <- start_container(name, port),
         :ok <- await_listener(port) do
      {:ok, %{container_id: String.trim(container_id), name: name, port: port}}
    else
      {_output, status} -> {:stop, {:minio_start, status}}
    end
  end

  @impl true
  def handle_call(:endpoint, _from, state),
    do: {:reply, DockerEndpoint.http_url(state.port), state}

  @impl true
  def handle_info({:EXIT, port, :normal}, state) when is_port(port), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ =
      System.cmd("docker", ["stop", "--timeout", "1", state.container_id], stderr_to_stdout: true)

    :ok
  end

  defp start_container(name, port) do
    System.cmd(
      "docker",
      [
        "run",
        "--detach",
        "--rm",
        "--name",
        name,
        "--publish",
        "#{DockerEndpoint.publish_address()}:#{port}:9000",
        "--env",
        "MINIO_ROOT_USER=robine-test-access",
        "--env",
        "MINIO_ROOT_PASSWORD=robine-test-secret-key",
        @image,
        "server",
        "/data",
        "--address",
        ":9000"
      ],
      stderr_to_stdout: true
    )
  end

  defp await_listener(port) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    connect_until_ready(port, deadline)
  end

  defp connect_until_ready(port, deadline) do
    case Req.get("#{DockerEndpoint.http_url(port)}/minio/health/live",
           retry: false,
           receive_timeout: 100,
           decode_body: false
         ) do
      {:ok, %{status: 200}} ->
        :ok

      _not_ready ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            20 -> connect_until_ready(port, deadline)
          end
        else
          {:error, :minio_start_timeout}
        end
    end
  end

  defp available_port do
    with {:ok, socket} <- :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false]),
         {:ok, {_address, port}} <- :inet.sockname(socket),
         :ok <- :gen_tcp.close(socket) do
      {:ok, port}
    end
  end
end
