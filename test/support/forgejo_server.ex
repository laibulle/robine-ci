defmodule Robine.TestSupport.ForgejoServer do
  @moduledoc false

  use GenServer

  @image "codeberg.org/forgejo/forgejo:16.0.2-rootless"
  @username "robine"
  @password "robine-integration-password"
  @repository "adapter-contract"

  def image, do: @image
  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options)
  def connection(server), do: GenServer.call(server, :connection)

  @impl true
  def init(_options) do
    Process.flag(:trap_exit, true)

    with {:ok, port} <- available_port(),
         name = "robine-forgejo-#{Ecto.UUID.generate()}",
         {container_id, 0} <- start_container(name, port),
         :ok <- await_listener(port),
         :ok <- create_user(name),
         {:ok, token} <- create_token(name),
         {:ok, sha} <- create_repository(port, token) do
      {:ok,
       %{
         container_id: String.trim(container_id),
         endpoint: "http://127.0.0.1:#{port}",
         name: name,
         repository: @repository,
         sha: sha,
         token: token,
         username: @username
       }}
    else
      {_output, status} when is_integer(status) -> {:stop, {:forgejo_start, status}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:connection, _from, state) do
    {:reply, Map.take(state, [:endpoint, :repository, :sha, :token, :username]), state}
  end

  @impl true
  def handle_info({:EXIT, port, :normal}, state) when is_port(port), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if container_id = Map.get(state, :container_id) do
      _ = System.cmd("docker", ["stop", "--timeout", "1", container_id], stderr_to_stdout: true)
    end

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
        "127.0.0.1:#{port}:3000",
        "--env",
        "FORGEJO__database__DB_TYPE=sqlite3",
        "--env",
        "FORGEJO__database__PATH=/var/lib/gitea/data/forgejo.db",
        "--env",
        "FORGEJO__security__INSTALL_LOCK=true",
        "--env",
        "FORGEJO__server__ROOT_URL=http://127.0.0.1:#{port}/",
        @image
      ],
      stderr_to_stdout: true
    )
  end

  defp await_listener(port) do
    deadline = System.monotonic_time(:millisecond) + 30_000
    connect_until_ready(port, deadline)
  end

  defp connect_until_ready(port, deadline) do
    case Req.get("http://127.0.0.1:#{port}/api/v1/version", retry: false, receive_timeout: 200) do
      {:ok, %{status: 200}} ->
        :ok

      _not_ready ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            25 -> connect_until_ready(port, deadline)
          end
        else
          {:error, :forgejo_start_timeout}
        end
    end
  end

  defp create_user(name) do
    case System.cmd(
           "docker",
           [
             "exec",
             "--user",
             "git",
             name,
             "forgejo",
             "admin",
             "user",
             "create",
             "--admin",
             "--username",
             @username,
             "--password",
             @password,
             "--email",
             "robine@example.test",
             "--must-change-password=false"
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:forgejo_user_creation, status, String.slice(output, 0, 200)}}
    end
  end

  defp create_token(name) do
    case System.cmd(
           "docker",
           [
             "exec",
             "--user",
             "git",
             name,
             "forgejo",
             "admin",
             "user",
             "generate-access-token",
             "--username",
             @username,
             "--token-name",
             "robine-adapter-contract",
             "--scopes",
             "all",
             "--raw"
           ],
           stderr_to_stdout: true
         ) do
      {token, 0} -> {:ok, String.trim(token)}
      {_output, status} -> {:error, {:forgejo_token_creation, status}}
    end
  end

  defp create_repository(port, token) do
    endpoint = "http://127.0.0.1:#{port}"

    with {:ok, %{status: 201}} <-
           Req.post("#{endpoint}/api/v1/user/repos",
             headers: auth_headers(token),
             json: %{
               name: @repository,
               private: true,
               auto_init: true,
               default_branch: "main"
             },
             retry: false
           ),
         {:ok, %{status: 201, body: body}} <-
           Req.post(
             "#{endpoint}/api/v1/repos/#{@username}/#{@repository}/contents/.robine-ci/workflows/ci.yml",
             headers: auth_headers(token),
             json: %{
               content:
                 Base.encode64("""
                 version: 1
                 name: Forgejo integration
                 jobs:
                   test:
                     image: alpine:3.22
                     steps:
                       - run: echo forgejo
                 """),
               message: "Add Robine workflow",
               branch: "main"
             },
             retry: false
           ),
         sha when is_binary(sha) <- get_in(body, ["commit", "sha"]) do
      {:ok, sha}
    else
      {:ok, %{status: status}} -> {:error, {:forgejo_fixture_request, status}}
      {:error, reason} -> {:error, {:forgejo_fixture_request, reason}}
      _invalid -> {:error, :invalid_forgejo_fixture_response}
    end
  end

  defp auth_headers(token), do: [{"authorization", "token #{token}"}]

  defp available_port do
    with {:ok, socket} <- :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false]),
         {:ok, {_address, port}} <- :inet.sockname(socket),
         :ok <- :gen_tcp.close(socket) do
      {:ok, port}
    end
  end
end
