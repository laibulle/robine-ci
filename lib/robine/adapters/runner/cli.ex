defmodule Robine.Adapters.Runner.CLI do
  @moduledoc "Standalone remote-runner command-line delivery adapter."

  import Bitwise

  alias Robine.Adapters.Runner.RemoteClient
  alias Robine.Adapters.Runner.DeploymentExecutor
  alias Robine.Adapters.Runner.RemoteExecutor
  alias Robine.Adapters.Runner.Capabilities
  alias Robine.Adapters.CLI.NativeRuntime

  @version Mix.Project.config()[:version]

  @spec main([String.t()]) :: no_return()
  def main(arguments) do
    case run(arguments) do
      {:exit, status, output} ->
        IO.puts(output)
        System.halt(status)

      {:start, config} ->
        start_foreground(config)
    end
  end

  @spec run([String.t()]) :: {:exit, non_neg_integer(), String.t()} | {:start, map()}
  def run(["version"]), do: {:exit, 0, "robine-runner #{@version}"}
  def run(["--version"]), do: run(["version"])

  def run(["enroll" | arguments]) do
    {options, positional, invalid} =
      OptionParser.parse(arguments,
        strict: [
          server: :string,
          name: :string,
          config: :string,
          force: :boolean,
          deployments: :boolean,
          deployment_root: :string
        ]
      )

    token = System.get_env("ROBINE_RUNNER_ENROLLMENT_TOKEN")
    System.delete_env("ROBINE_RUNNER_ENROLLMENT_TOKEN")

    cond do
      invalid != [] or positional != [] ->
        usage("invalid enroll arguments")

      not is_binary(options[:server]) ->
        usage("--server is required")

      not is_binary(options[:name]) ->
        usage("--name is required")

      not is_binary(options[:config]) ->
        usage("--config is required")

      options[:deployments] == true and not is_binary(options[:deployment_root]) ->
        usage("--deployment-root is required with --deployments")

      not is_binary(token) or token == "" ->
        usage("ROBINE_RUNNER_ENROLLMENT_TOKEN is required")

      true ->
        enroll(options, token)
    end
  end

  def run(["start" | arguments]) do
    {options, positional, invalid} = OptionParser.parse(arguments, strict: [config: :string])

    cond do
      invalid != [] or positional != [] -> usage("invalid start arguments")
      not is_binary(options[:config]) -> usage("--config is required")
      true -> load_config(options[:config])
    end
  end

  def run(_arguments), do: usage("expected version, enroll, or start")

  defp enroll(options, token) do
    with {:ok, _socket_url} <- RemoteClient.socket_url(options[:server]),
         :ok <- available_path(options[:config], options[:force]),
         {:ok, response} <- enrollment_request(options, token),
         {:ok, config} <-
           enrollment_config(
             response.body,
             options[:server],
             options[:name],
             options[:deployments] || false,
             options[:deployment_root]
           ),
         :ok <- write_private_config(options[:config], config) do
      {:exit, 0,
       "Runner enrolled as #{config["runner_id"]}. Credential stored in #{Path.expand(options[:config])}."}
    else
      {:error, :already_exists} ->
        {:exit, 4, "Config already exists; pass --force to replace it."}

      {:error, :tls_required} ->
        {:exit, 2, "TLS is required except for a loopback server."}

      {:error, {:http, status}} ->
        {:exit, 3, "Enrollment failed with HTTP #{status}."}

      {:error, reason} ->
        {:exit, 3, "Enrollment failed: #{safe_reason(reason)}"}
    end
  end

  defp enrollment_request(options, token) do
    url = String.trim_trailing(options[:server], "/") <> "/api/v1/runners/enroll"

    with {:ok, _applications} <- Application.ensure_all_started(:req) do
      case Req.post(url: url, json: %{token: token, name: options[:name]}) do
        {:ok, %{status: 201} = response} -> {:ok, response}
        {:ok, %{status: status}} -> {:error, {:http, status}}
        {:error, exception} -> {:error, {:request, exception.__struct__}}
      end
    end
  end

  defp enrollment_config(
         %{"runner_id" => runner_id, "credential" => credential},
         server,
         name,
         deployments?,
         deployment_root
       )
       when is_binary(runner_id) and is_binary(credential) do
    {:ok,
     %{
       "server_url" => server,
       "runner_id" => runner_id,
       "credential" => credential,
       "name" => name,
       "deployments" => deployments?,
       "deployment_roots" => deployment_roots(deployments?, deployment_root),
       "executor" => Capabilities.detect()["executor"]
     }}
  end

  defp enrollment_config(_body, _server, _name, _deployments?, _deployment_root),
    do: {:error, :invalid_server_response}

  defp deployment_roots(true, root), do: [Path.expand(root)]
  defp deployment_roots(false, _root), do: []

  defp available_path(path, true), do: ensure_parent(path)

  defp available_path(path, _force) do
    if File.exists?(path), do: {:error, :already_exists}, else: ensure_parent(path)
  end

  defp ensure_parent(path), do: File.mkdir_p(Path.dirname(Path.expand(path)))

  defp write_private_config(path, config) do
    expanded = Path.expand(path)
    temporary = expanded <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(temporary, Jason.encode!(config), [:binary, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, expanded) do
      :ok
    else
      {:error, reason} = error ->
        File.rm(temporary)
        if reason == :eexist, do: {:error, :already_exists}, else: error
    end
  end

  defp load_config(path) do
    with {:ok, stat} <- File.stat(path),
         true <- private_mode?(stat.mode),
         {:ok, encoded} <- File.read(path),
         {:ok, config} <- Jason.decode(encoded),
         :ok <- validate_config(config) do
      {:start, Map.put(config, "executor", Capabilities.detect()["executor"])}
    else
      false -> {:exit, 4, "Runner config must not be readable or writable by group or others."}
      {:error, reason} -> {:exit, 3, "Cannot load runner config: #{safe_reason(reason)}"}
    end
  end

  defp private_mode?(mode), do: (mode &&& 0o077) == 0

  defp validate_config(
         %{
           "server_url" => server_url,
           "runner_id" => runner_id,
           "credential" => credential
         } = config
       )
       when is_binary(server_url) and is_binary(runner_id) and is_binary(credential) do
    with :ok <- valid_deployment_config(config),
         {:ok, _url} <- RemoteClient.socket_url(server_url) do
      :ok
    end
  end

  defp validate_config(_config), do: {:error, :invalid_config}

  defp valid_deployment_config(%{"deployments" => true, "deployment_roots" => roots})
       when is_list(roots) and roots != [] do
    if Enum.all?(roots, &(is_binary(&1) and Path.type(&1) == :absolute)),
      do: :ok,
      else: {:error, :invalid_deployment_roots}
  end

  defp valid_deployment_config(%{"deployments" => false}), do: :ok
  defp valid_deployment_config(config) when not is_map_key(config, "deployments"), do: :ok
  defp valid_deployment_config(_config), do: {:error, :invalid_deployment_config}

  defp start_foreground(config) do
    :ok = prepare_native_runtime!()
    {:ok, _applications} = Application.ensure_all_started(:websockex)
    {:ok, _applications} = Application.ensure_all_started(:req)

    case RemoteClient.start_link(
           server_url: config["server_url"],
           runner_id: config["runner_id"],
           credential: config["credential"],
           owner: self(),
           software_version: @version,
           capabilities:
             Capabilities.detect(
               :os.type(),
               to_string(:erlang.system_info(:system_architecture)),
               config["deployments"] == true
             )
         ) do
      {:ok, client} ->
        monitor(client, config)

      {:error, reason} ->
        IO.puts(:stderr, "Runner failed to start: #{safe_reason(reason)}")
        System.halt(3)
    end
  end

  defp prepare_native_runtime! do
    case NativeRuntime.prepare() do
      :ok -> :ok
      {:error, reason} -> raise "runner native runtime is unavailable: #{inspect(reason)}"
    end
  end

  defp monitor(client, config) do
    reference = Process.monitor(client)
    monitor_loop(client, reference, config, %{})
  end

  defp monitor_loop(client, reference, config, executions) do
    receive do
      {:runner_connection, :connected} ->
        IO.puts("Connected; negotiating runner protocol.")
        monitor_loop(client, reference, config, executions)

      {:runner_connection, :ready, welcome} ->
        IO.puts("Runner ready with protocol #{welcome["protocol_version"]}.")
        monitor_loop(client, reference, config, executions)

      {:runner_connection, :disconnected, _reason, delay} ->
        IO.puts(:stderr, "Disconnected; reconnecting in #{delay} ms.")
        monitor_loop(client, reference, config, executions)

      {:runner_message, "job_offer", offer} ->
        executions = start_execution(offer, client, config, executions)
        monitor_loop(client, reference, config, executions)

      {:runner_message, "deployment_offer", offer} ->
        executions = start_deployment(offer, client, config, executions)
        monitor_loop(client, reference, config, executions)

      {:runner_message, "cancel", %{"attempt_id" => attempt_id}} ->
        case Map.get(executions, attempt_id) do
          {pid, _monitor} -> send(pid, :cancel_requested)
          nil -> :ok
        end

        monitor_loop(client, reference, config, executions)

      {:runner_message, "runner_revoked", %{"cancel_active_attempts" => true}} ->
        Enum.each(executions, fn {_attempt_id, {pid, _monitor}} ->
          send(pid, :cancel_requested)
        end)

        monitor_loop(client, reference, config, executions)

      {:remote_execution_finished, attempt_id, pid, _result} ->
        executions = finish_execution(executions, attempt_id, pid)
        monitor_loop(client, reference, config, executions)

      {:deployment_execution_finished, deployment_id, pid, _result} ->
        executions = finish_execution(executions, {:deployment, deployment_id}, pid)
        monitor_loop(client, reference, config, executions)

      {:DOWN, ^reference, :process, ^client, reason} ->
        IO.puts(:stderr, "Runner stopped: #{safe_reason(reason)}")
        System.halt(3)

      {:DOWN, monitor, :process, _pid, _reason} ->
        executions = remove_execution_by_monitor(executions, monitor)
        monitor_loop(client, reference, config, executions)

      _message ->
        monitor_loop(client, reference, config, executions)
    end
  end

  defp start_execution(%{"attempt_id" => attempt_id} = offer, client, config, executions)
       when is_binary(attempt_id) do
    if Map.has_key?(executions, attempt_id) do
      executions
    else
      owner = self()

      {pid, monitor} =
        spawn_monitor(fn ->
          result = RemoteExecutor.run(offer, client, config)
          send(owner, {:remote_execution_finished, attempt_id, self(), result})
        end)

      Map.put(executions, attempt_id, {pid, monitor})
    end
  end

  defp start_execution(_offer, _client, _config, executions), do: executions

  defp start_deployment(%{"deployment_id" => deployment_id} = offer, client, config, executions)
       when is_binary(deployment_id) do
    key = {:deployment, deployment_id}

    if Map.has_key?(executions, key) do
      executions
    else
      owner = self()

      {pid, monitor} =
        spawn_monitor(fn ->
          result = DeploymentExecutor.run(offer, client, config)
          send(owner, {:deployment_execution_finished, deployment_id, self(), result})
        end)

      Map.put(executions, key, {pid, monitor})
    end
  end

  defp start_deployment(_offer, _client, _config, executions), do: executions

  defp finish_execution(executions, attempt_id, pid) do
    case Map.get(executions, attempt_id) do
      {^pid, monitor} ->
        Process.demonitor(monitor, [:flush])
        Map.delete(executions, attempt_id)

      _missing_or_replaced ->
        executions
    end
  end

  defp remove_execution_by_monitor(executions, monitor) do
    Enum.reduce(executions, executions, fn
      {attempt_id, {_pid, ^monitor}}, current -> Map.delete(current, attempt_id)
      _entry, current -> current
    end)
  end

  defp usage(message) do
    {:exit, 64,
     "#{message}\n" <>
       "Usage:\n" <>
       "  robine-runner version\n" <>
       "  ROBINE_RUNNER_ENROLLMENT_TOKEN=... robine-runner enroll --server URL --name NAME --config FILE [--deployments --deployment-root DIR]\n" <>
       "  robine-runner start --config FILE"}
  end

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({tag, detail}) when is_atom(tag) and is_atom(detail), do: "#{tag}: #{detail}"
  defp safe_reason(_reason), do: "unexpected error"
end
