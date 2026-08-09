defmodule Robine.TestSupport.GitLabServer do
  @moduledoc false

  use GenServer

  @image "gitlab/gitlab-ce:19.2.1-ce.0"
  @root_password "R0b!ne-19.2#xQ7vL4pZ8mK2"
  @token "glpat-robine-integration-token-00000001"
  @project "adapter-contract"

  def image, do: @image
  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options)
  def connection(server), do: GenServer.call(server, :connection)

  @impl true
  def init(_options) do
    Process.flag(:trap_exit, true)

    with {:ok, port} <- available_port(),
         name = "robine-gitlab-#{Ecto.UUID.generate()}",
         {container_id, 0} <- start_container(name, port) do
      case initialize_fixture(name, port) do
        {:ok, project_id, sha} ->
          {:ok,
           %{
             container_id: String.trim(container_id),
             endpoint: "http://127.0.0.1:#{port}",
             name: name,
             project: @project,
             project_id: project_id,
             sha: sha,
             token: @token
           }}

        {:error, reason} ->
          cleanup_container(name)
          {:stop, reason}
      end
    else
      {_output, status} when is_integer(status) -> {:stop, {:gitlab_start, status}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:connection, _from, state) do
    {:reply, Map.take(state, [:endpoint, :project, :project_id, :sha, :token]), state}
  end

  @impl true
  def handle_info({:EXIT, port, :normal}, state) when is_port(port), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if name = Map.get(state, :name), do: cleanup_container(name)

    :ok
  end

  defp initialize_fixture(name, port) do
    with :ok <- await_listener(name, port),
         :ok <- create_token(name),
         {:ok, project_id, sha} <- create_project(port) do
      {:ok, project_id, sha}
    end
  end

  defp start_container(name, port) do
    omnibus_config = """
    external_url 'http://127.0.0.1:#{port}'
    gitlab_rails['nginx']['listen_port'] = 80
    gitlab_rails['initial_root_password'] = '#{@root_password}'
    prometheus_monitoring['enable'] = false
    alertmanager['enable'] = false
    node_exporter['enable'] = false
    redis_exporter['enable'] = false
    postgres_exporter['enable'] = false
    gitlab_exporter['enable'] = false
    """

    System.cmd(
      "docker",
      [
        "run",
        "--detach",
        "--name",
        name,
        "--shm-size",
        "256m",
        "--publish",
        "127.0.0.1:#{port}:80",
        "--env",
        "GITLAB_OMNIBUS_CONFIG=#{omnibus_config}",
        @image
      ],
      stderr_to_stdout: true
    )
  end

  defp await_listener(name, port) do
    deadline = System.monotonic_time(:millisecond) + 300_000
    connect_until_ready(name, port, deadline)
  end

  defp connect_until_ready(name, port, deadline) do
    case Req.get("http://127.0.0.1:#{port}/api/v4/version", retry: false, receive_timeout: 500) do
      {:ok, %{status: status}} when status in [200, 401] ->
        :ok

      _not_ready ->
        cond do
          not container_running?(name) ->
            {:error, {:gitlab_exited_during_startup, bounded_logs(name)}}

          System.monotonic_time(:millisecond) >= deadline ->
            {:error, :gitlab_start_timeout}

          true ->
            receive do
            after
              100 -> connect_until_ready(name, port, deadline)
            end
        end
    end
  end

  defp container_running?(name) do
    case System.cmd("docker", ["inspect", "--format", "{{.State.Running}}", name],
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> true
      _not_running -> false
    end
  end

  defp bounded_logs(name) do
    case System.cmd("docker", ["logs", "--tail", "80", name], stderr_to_stdout: true) do
      {output, _status} -> String.slice(output, 0, 8_000)
    end
  end

  defp cleanup_container(name) do
    _ = System.cmd("docker", ["rm", "--force", name], stderr_to_stdout: true)
    :ok
  end

  defp create_token(name) do
    script = """
    user = User.find_by_username('root')
    token = user.personal_access_tokens.create!(name: 'robine-adapter-contract', scopes: ['api'], expires_at: 1.day.from_now)
    token.set_token('#{@token}')
    token.save!
    """

    case System.cmd(
           "docker",
           ["exec", name, "gitlab-rails", "runner", String.replace(script, "\n", "; ")],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, {:gitlab_token_creation, status}}
    end
  end

  defp create_project(port) do
    endpoint = "http://127.0.0.1:#{port}"

    with {:ok, %{status: 201, body: %{"id" => project_id}}} when is_integer(project_id) <-
           Req.post("#{endpoint}/api/v4/projects",
             headers: auth_headers(),
             json: %{
               name: @project,
               path: @project,
               visibility: "private",
               initialize_with_readme: true,
               default_branch: "main"
             },
             retry: false,
             receive_timeout: 10_000
           ),
         {:ok, %{status: 201}} <-
           Req.post(
             "#{endpoint}/api/v4/projects/#{project_id}/repository/files/.robine-ci%2Fworkflows%2Fci.yml",
             headers: auth_headers(),
             json: %{
               branch: "main",
               commit_message: "Add Robine workflow",
               content: """
               version: 1
               name: GitLab integration
               jobs:
                 test:
                   image: alpine:3.22
                   steps:
                     - run: echo gitlab
               """
             },
             retry: false,
             receive_timeout: 10_000
           ),
         {:ok, %{status: 200, body: %{"id" => sha}}} when is_binary(sha) <-
           Req.get("#{endpoint}/api/v4/projects/#{project_id}/repository/commits/main",
             headers: auth_headers(),
             retry: false,
             receive_timeout: 10_000
           ) do
      {:ok, project_id, sha}
    else
      {:ok, %{status: status}} -> {:error, {:gitlab_fixture_request, status}}
      {:error, reason} -> {:error, {:gitlab_fixture_request, reason}}
      _invalid -> {:error, :invalid_gitlab_fixture_response}
    end
  end

  defp auth_headers, do: [{"private-token", @token}]

  defp available_port do
    with {:ok, socket} <- :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false]),
         {:ok, {_address, port}} <- :inet.sockname(socket),
         :ok <- :gen_tcp.close(socket) do
      {:ok, port}
    end
  end
end
