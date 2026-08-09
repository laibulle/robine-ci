defmodule Robine.Adapters.Execution.DockerRunner do
  @moduledoc false
  @behaviour Robine.Execution.Ports.Runner

  alias Robine.Execution.Contracts.{Result, Specification, Step, StepResult}
  alias Robine.Adapters.Archive.SafeTar
  alias Robine.Secrets.Domain.Redactor

  @output_limit 10_000_000
  @service_diagnostic_limit 64_000
  @readiness_image "alpine@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce"
  @attempt_label "io.robine.attempt"
  @service_label "io.robine.service"

  def run(%Specification{} = specification) do
    run(specification, fn _event -> :ok end, fn -> false end)
  end

  def run(%Specification{} = specification, on_output) when is_function(on_output, 1) do
    run(specification, on_output, fn -> false end)
  end

  @impl true
  def run(%Specification{} = specification, on_output, cancel_requested)
      when is_function(on_output, 1) and is_function(cancel_requested, 0) do
    started_at = DateTime.utc_now()
    resource = resource_name(specification.attempt_id)
    volume = resource <> "-workspace"
    network = if specification.services == [], do: nil, else: resource <> "-network"

    with :ok <- prepare_images(specification, on_output) do
      case provision(specification, resource, volume, network, on_output, cancel_requested) do
        :ok ->
          run_owned(
            specification,
            resource,
            volume,
            network,
            started_at,
            on_output,
            cancel_requested
          )

        {:error, :duplicate_attempt} ->
          {:error, {:docker, :duplicate_attempt}}

        {:error, {:service_unavailable, _service_id, :cancelled, _diagnostic}} ->
          cleanup_warning = cleanup(specification, resource, volume, network)

          {:ok,
           %Result{
             attempt_id: specification.attempt_id,
             status: :cancelled,
             reason: :cancelled,
             steps: [],
             started_at: started_at,
             finished_at: DateTime.utc_now(),
             cleanup_warning: cleanup_warning
           }}

        {:error, reason} ->
          _cleanup_warning = cleanup(specification, resource, volume, network)
          {:error, {:docker, reason}}
      end
    end
  end

  defp run_owned(
         specification,
         resource,
         volume,
         network,
         started_at,
         on_output,
         cancel_requested
       ) do
    with :ok <- copy_source(specification.source_path, resource, specification.workspace),
         :ok <- start_container(resource, specification.shell),
         :ok <- ensure_shell(resource, specification.shell),
         {:ok, step_results} <-
           run_steps(specification, resource, on_output, cancel_requested) do
      cleanup_warning = cleanup(specification, resource, volume, network)

      {:ok,
       %Result{
         attempt_id: specification.attempt_id,
         status: :succeeded,
         reason: nil,
         steps: step_results,
         started_at: started_at,
         finished_at: DateTime.utc_now(),
         cleanup_warning: cleanup_warning
       }}
    else
      {:step_failed, step_results, reason} ->
        cleanup_warning = cleanup(specification, resource, volume, network)

        {:ok,
         %Result{
           attempt_id: specification.attempt_id,
           status: :failed,
           reason: reason,
           steps: step_results,
           started_at: started_at,
           finished_at: DateTime.utc_now(),
           cleanup_warning: cleanup_warning
         }}

      {:step_cancelled, step_results} ->
        cleanup_warning = cleanup(specification, resource, volume, network)

        {:ok,
         %Result{
           attempt_id: specification.attempt_id,
           status: :cancelled,
           reason: :cancelled,
           steps: step_results,
           started_at: started_at,
           finished_at: DateTime.utc_now(),
           cleanup_warning: cleanup_warning
         }}

      {:error, reason} ->
        _cleanup_warning = cleanup(specification, resource, volume, network)
        {:error, {:docker, reason}}
    end
  end

  defp provision(specification, resource, volume, network, on_output, cancel_requested) do
    with :ok <- create_network(specification, network),
         {:ok, _output} <-
           docker(["volume", "create", "--label", label(specification), volume]),
         :ok <-
           create_services(specification, resource, network, on_output, cancel_requested),
         {:ok, _output} <- create_container(specification, resource, volume, network) do
      :ok
    end
  end

  @impl true
  def reconcile_resources(active_attempt_ids) do
    active = MapSet.new(active_attempt_ids)

    with {:ok, containers} <- labeled_resources(:container),
         {:ok, removed_containers} <- remove_orphans(containers, active, :container),
         {:ok, volumes} <- labeled_resources(:volume),
         {:ok, removed_volumes} <- remove_orphans(volumes, active, :volume),
         {:ok, networks} <- labeled_resources(:network),
         {:ok, removed_networks} <- remove_orphans(networks, active, :network) do
      {:ok,
       %{
         containers_removed: removed_containers,
         volumes_removed: removed_volumes,
         networks_removed: removed_networks
       }}
    end
  end

  defp labeled_resources(:container) do
    case docker([
           "ps",
           "--all",
           "--filter",
           "label=#{@attempt_label}",
           "--format",
           "{{.ID}} {{.Label \"#{@attempt_label}\"}}"
         ]) do
      {:ok, output} -> parse_labeled_resources(output)
      error -> error
    end
  end

  defp labeled_resources(:volume) do
    case docker([
           "volume",
           "ls",
           "--filter",
           "label=#{@attempt_label}",
           "--format",
           "{{.Name}} {{.Label \"#{@attempt_label}\"}}"
         ]) do
      {:ok, output} -> parse_labeled_resources(output)
      error -> error
    end
  end

  defp labeled_resources(:network) do
    case docker([
           "network",
           "ls",
           "--filter",
           "label=#{@attempt_label}",
           "--format",
           "{{.ID}} {{.Label \"#{@attempt_label}\"}}"
         ]) do
      {:ok, output} -> parse_labeled_resources(output)
      error -> error
    end
  end

  @doc false
  def parse_labeled_resources(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, resources} ->
      case String.split(line, ~r/\s+/, parts: 2) do
        [name, attempt_id] when name != "" and attempt_id != "" ->
          {:cont, {:ok, [%{name: name, attempt_id: attempt_id} | resources]}}

        _ ->
          {:halt, {:error, :invalid_labeled_resource_output}}
      end
    end)
    |> case do
      {:ok, resources} -> {:ok, Enum.reverse(resources)}
      error -> error
    end
  end

  defp remove_orphans(resources, active, type) do
    resources
    |> Enum.reject(&MapSet.member?(active, &1.attempt_id))
    |> Enum.reduce_while({:ok, 0}, fn resource, {:ok, count} ->
      args =
        case type do
          :container -> ["rm", "--force", "--volumes", resource.name]
          :volume -> ["volume", "rm", "--force", resource.name]
          :network -> ["network", "rm", resource.name]
        end

      case docker(args) do
        {:ok, _output} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, {:orphan_cleanup, type, reason}}}
      end
    end)
  end

  defp prepare_images(specification, callback) do
    with :ok <-
           prepare_image(
             specification.image,
             specification.timeout_ms,
             callback,
             "Image acquisition",
             1
           ) do
      with :ok <- prepare_service_images(specification, callback),
           :ok <- prepare_readiness_image(specification, callback) do
        :ok
      end
    end
  end

  defp prepare_service_images(specification, callback) do
    specification.services
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {service, index}, :ok ->
      case prepare_image(
             service.image,
             specification.timeout_ms,
             callback,
             "Service #{service.id}",
             index * 10 + 1
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:service_image, service.id, reason}}}
      end
    end)
  end

  defp prepare_readiness_image(%Specification{services: services} = specification, callback) do
    if Enum.any?(services, & &1.readiness) do
      case prepare_image(
             @readiness_image,
             specification.timeout_ms,
             callback,
             "Service readiness probe",
             91
           ) do
        :ok -> :ok
        {:error, reason} -> {:error, {:readiness_image, reason}}
      end
    else
      :ok
    end
  end

  defp prepare_image(image, timeout_ms, callback, step_name, sequence) do
    started = System.monotonic_time(:millisecond)

    with :ok <- emit_phase(callback, sequence, :running, started, "Acquiring #{image}", step_name),
         {:ok, detail} <- acquire_image(image, timeout_ms),
         :ok <- emit_phase(callback, sequence + 1, :succeeded, started, detail, step_name) do
      :ok
    else
      {:error, reason} = error ->
        _ =
          emit_phase(
            callback,
            sequence + 1,
            :failed,
            started,
            "Image acquisition failed",
            step_name
          )

        if match?({:image_acquisition, _}, reason),
          do: error,
          else: {:error, {:image_acquisition, reason}}
    end
  end

  defp acquire_image(image, timeout_ms) do
    case docker(["image", "inspect", image], 5_000) do
      {:ok, _output} ->
        {:ok, "Image available locally"}

      {:error, %{exit_code: 1}} ->
        case docker(["pull", image], min(timeout_ms, 300_000)) do
          {:ok, _output} -> {:ok, "Image pulled successfully"}
          {:error, reason} -> {:error, {:image_pull, reason}}
        end

      {:error, reason} ->
        {:error, {:image_inspect, reason}}
    end
  end

  defp emit_phase(callback, sequence, status, started, content, step_name) do
    callback.(%{
      sequence: sequence,
      phase: :image_acquisition,
      step_position: 0,
      step_name: step_name,
      status: status,
      exit_code: if(status == :failed, do: 1, else: nil),
      duration_ms: System.monotonic_time(:millisecond) - started,
      stream: :system,
      content: content
    })
  end

  defp create_network(_specification, nil), do: :ok

  defp create_network(specification, network) do
    case docker(["network", "create", "--label", label(specification), network]) do
      {:ok, _output} ->
        :ok

      {:error, %{output: output}} ->
        if String.contains?(output, "already exists"),
          do: {:error, :duplicate_attempt},
          else:
            {:error,
             {:network_create, redact_and_truncate(output, service_secret_values(specification))}}
    end
  end

  defp create_services(
         %Specification{services: []},
         _resource,
         _network,
         _on_output,
         _cancel_requested
       ),
       do: :ok

  defp create_services(specification, resource, network, on_output, cancel_requested) do
    specification.services
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {service, index}, :ok ->
      name = service_resource_name(resource, service.id)
      started = System.monotonic_time(:millisecond)
      sequence = 100 + index * 2

      with :ok <-
             emit_service_phase(
               on_output,
               service,
               sequence,
               :running,
               started,
               "Starting service"
             ),
           {:ok, _output} <- create_service(specification, service, name, network),
           {:ok, _output} <- docker(["start", name], specification.timeout_ms),
           :ok <- await_service(service, name, network, cancel_requested, specification),
           :ok <-
             emit_service_phase(
               on_output,
               service,
               sequence + 1,
               :succeeded,
               started,
               "Service ready"
             ) do
        {:cont, :ok}
      else
        {:error, :duplicate_attempt} ->
          {:halt, {:error, :duplicate_attempt}}

        {:error, reason} ->
          diagnostic = service_diagnostic(name, service_secret_values(specification))

          _ =
            emit_service_phase(
              on_output,
              service,
              sequence + 1,
              :failed,
              started,
              "Service failed: #{diagnostic}"
            )

          {:halt, {:error, {:service_unavailable, service.id, reason, diagnostic}}}
      end
    end)
  end

  defp emit_service_phase(callback, service, sequence, status, started, content) do
    callback.(%{
      sequence: sequence,
      phase: :service_preparation,
      step_position: 0,
      step_name: "Service #{service.id}",
      status: status,
      exit_code: if(status == :failed, do: 1, else: nil),
      duration_ms: System.monotonic_time(:millisecond) - started,
      stream: :system,
      content: content
    })
  end

  defp create_service(specification, service, name, network) do
    environment = Map.merge(service.env, service.secret_env)

    security_args =
      if service.privileged,
        do: ["--privileged"],
        else: ["--cap-drop", "ALL", "--security-opt", "no-new-privileges"]

    args =
      [
        "create",
        "--name",
        name,
        "--label",
        label(specification),
        "--label",
        "#{@service_label}=#{service.id}",
        security_args,
        resource_limit_args(),
        "--network",
        network,
        "--network-alias",
        service.id,
        "--tmpfs",
        "/tmp:rw,noexec,nosuid,size=256m"
      ]
      |> List.flatten()
      |> Kernel.++(
        service_user_args(service.user) ++
          environment_args(environment) ++ [service.image] ++ service.command
      )

    case docker(args, specification.timeout_ms) do
      {:error, %{output: output}} = error ->
        if String.contains?(output, "already in use") or
             String.contains?(output, "already exists") do
          {:error, :duplicate_attempt}
        else
          redact_error(error, service_secret_values(specification))
        end

      result ->
        result
    end
  end

  defp await_service(service, name, network, cancel_requested, specification) do
    timeout_ms = if service.readiness, do: service.readiness.timeout_ms, else: 5_000
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_service_until(service, name, network, cancel_requested, specification, deadline)
  end

  defp await_service_until(
         service,
         name,
         network,
         cancel_requested,
         specification,
         deadline
       ) do
    cond do
      cancel_requested.() ->
        {:error, :cancelled}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, {:readiness_timeout, service.readiness && service.readiness.timeout_ms}}

      true ->
        case service_state(name) do
          {:ok, %{running: false, status: status}} ->
            {:error, {:service_exited, status}}

          {:ok, %{running: true}} when is_nil(service.readiness) ->
            :ok

          {:ok, %{running: true}} ->
            if tcp_ready?(network, service.id, service.readiness.tcp) do
              :ok
            else
              wait_for_service_poll(
                service,
                name,
                network,
                cancel_requested,
                specification,
                deadline
              )
            end

          {:error, reason} ->
            {:error, {:service_inspect, reason}}
        end
    end
  end

  defp wait_for_service_poll(
         service,
         name,
         network,
         cancel_requested,
         specification,
         deadline
       ) do
    receive do
    after
      100 ->
        await_service_until(
          service,
          name,
          network,
          cancel_requested,
          specification,
          deadline
        )
    end
  end

  defp service_state(name) do
    case docker(
           [
             "inspect",
             "--format",
             "{{.State.Running}} {{.State.Status}} {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
             name
           ],
           2_000
         ) do
      {:ok, output} ->
        case String.split(String.trim(output), ~r/\s+/, parts: 3) do
          ["true", status, ip] -> {:ok, %{running: true, status: status, ip: ip}}
          ["false", status] -> {:ok, %{running: false, status: status, ip: nil}}
          ["false", status, _ip] -> {:ok, %{running: false, status: status, ip: nil}}
          _invalid -> {:error, :invalid_service_inspect}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tcp_ready?(network, service_id, port) do
    case docker(
           [
             "run",
             "--rm",
             "--pull",
             "never",
             "--cap-drop",
             "ALL",
             "--security-opt",
             "no-new-privileges",
             "--network",
             network,
             @readiness_image,
             "nc",
             "-z",
             "-w",
             "1",
             service_id,
             to_string(port)
           ],
           2_000
         ) do
      {:ok, _output} -> true
      {:error, _reason} -> false
    end
  end

  defp service_diagnostic(name, secret_values) do
    case docker(["logs", "--tail", "200", name], 2_000) do
      {:ok, output} -> bounded_service_diagnostic(output, secret_values)
      {:error, %{output: output}} -> bounded_service_diagnostic(output, secret_values)
    end
  end

  defp bounded_service_diagnostic(output, secret_values) do
    output = redact_and_truncate(output, secret_values)

    if byte_size(output) <= @service_diagnostic_limit,
      do: output,
      else:
        binary_part(
          output,
          byte_size(output) - @service_diagnostic_limit,
          @service_diagnostic_limit
        )
  end

  defp create_container(specification, resource, volume, network) do
    args =
      [
        "create",
        "--name",
        resource,
        "--label",
        label(specification),
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges",
        resource_limit_args(),
        "--network",
        network || "bridge",
        "--mount",
        "type=volume,source=#{volume},target=#{specification.workspace}",
        "--tmpfs",
        "/tmp:rw,noexec,nosuid,size=256m"
      ]
      |> List.flatten()
      |> Kernel.++(
        environment_args(specification.env) ++
          environment_args(specification.secrets) ++
          [
            specification.image,
            specification.shell,
            "-c",
            "trap 'exit 0' TERM INT; while :; do sleep 3600; done"
          ]
      )

    case docker(args, specification.timeout_ms) do
      {:error, %{output: output}} = error ->
        if String.contains?(output, "already in use") or
             String.contains?(output, "already exists") do
          {:error, :duplicate_attempt}
        else
          redact_error(error, Map.values(specification.secrets))
        end

      result ->
        result
    end
  end

  @doc false
  @spec resource_limit_args(keyword()) :: [String.t()]
  def resource_limit_args(config \\ Application.fetch_env!(:robine, :runner_resources)) do
    cpu_millis = Keyword.fetch!(config, :cpu_millis)
    memory_bytes = Keyword.fetch!(config, :memory_bytes)
    pids_limit = Keyword.fetch!(config, :pids_limit)

    [
      "--cpus",
      cpu_limit(cpu_millis),
      "--memory",
      Integer.to_string(memory_bytes),
      "--memory-swap",
      Integer.to_string(memory_bytes),
      "--pids-limit",
      Integer.to_string(pids_limit)
    ]
  end

  defp cpu_limit(cpu_millis) do
    whole = div(cpu_millis, 1_000)
    fraction = cpu_millis |> rem(1_000) |> Integer.to_string() |> String.pad_leading(3, "0")
    "#{whole}.#{fraction}"
  end

  defp ensure_shell(resource, shell) do
    case docker(["exec", resource, shell, "-c", "true"], 5_000) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:shell_unavailable, shell, reason}}
    end
  end

  defp start_container(resource, shell) do
    case docker(["start", resource]) do
      {:ok, _output} ->
        :ok

      {:error, %{output: output} = reason} ->
        if String.contains?(output, shell) and
             String.contains?(output, "no such file or directory"),
           do: {:error, {:shell_unavailable, shell, reason}},
           else: {:error, {:container_start, reason}}
    end
  end

  defp copy_source(nil, _resource, _workspace), do: :ok

  defp copy_source(source_path, resource, workspace) do
    with {:ok, staged_path} <- stage_source(source_path) do
      try do
        case docker(["cp", staged_path <> "/.", "#{resource}:#{workspace}"]) do
          {:ok, _output} -> :ok
          {:error, reason} -> {:error, {:copy_source, reason}}
        end
      after
        File.rm_rf(Path.dirname(staged_path))
      end
    end
  end

  defp stage_source(source_path) do
    staging_root = Path.join(System.tmp_dir!(), "robine-docker-source-#{Ecto.UUID.generate()}")
    staged_path = Path.join(staging_root, "workspace")

    with :ok <- validate_source_tree(source_path),
         :ok <- File.mkdir(staging_root),
         {:ok, _entries} <- File.cp_r(source_path, staged_path),
         :ok <- make_staged_tree_accessible(staged_path) do
      {:ok, staged_path}
    else
      {:error, reason} ->
        File.rm_rf(staging_root)
        {:error, {:unsafe_source_tree, reason}}
    end
  end

  defp validate_source_tree(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        with {:ok, entries} <- File.ls(path) do
          Enum.reduce_while(entries, :ok, fn entry, :ok ->
            case validate_source_tree(Path.join(path, entry)) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        end

      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsupported_file_type, type, path}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp make_staged_tree_accessible(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        with :ok <- File.chmod(path, 0o777),
             {:ok, entries} <- File.ls(path) do
          Enum.reduce_while(entries, :ok, fn entry, :ok ->
            case make_staged_tree_accessible(Path.join(path, entry)) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        end

      {:ok, %File.Stat{type: :regular}} ->
        File.chmod(path, 0o666)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_steps(specification, resource, on_output, cancel_requested) do
    specification.steps
    |> Enum.with_index(1)
    |> Enum.reduce_while({:running, [], nil}, fn {step, position},
                                                 {:running, results, first_failure} ->
      cond do
        cancel_requested.() ->
          {:halt, {:step_cancelled, results}}

        condition_matches?(step.condition, first_failure) ->
          case run_step(step, position, specification, resource, on_output, cancel_requested) do
            {:ok, result} ->
              {:cont, {:running, results ++ [result], first_failure}}

            {:failed, result, :command_failed} ->
              failure = first_failure || :command_failed
              {:cont, {:running, results ++ [result], failure}}

            {:failed, result, reason} ->
              {:halt, {:step_failed, results ++ [result], reason}}

            {:cancelled, result} ->
              {:halt, {:step_cancelled, results ++ [result]}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        true ->
          case skip_step(step, position, on_output, first_failure) do
            {:ok, result} -> {:cont, {:running, results ++ [result], first_failure}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:running, results, nil} -> {:ok, results}
      {:running, results, first_failure} -> {:step_failed, results, first_failure}
      terminal -> terminal
    end
  end

  defp condition_matches?(:success, nil), do: true
  defp condition_matches?(:success, _failure), do: false
  defp condition_matches?(:failure, nil), do: false
  defp condition_matches?(:failure, _failure), do: true
  defp condition_matches?(:always, _failure), do: true

  defp skip_step(step, position, on_output, first_failure) do
    outcome = if is_nil(first_failure), do: "success", else: "failure"
    message = "Skipped because if: #{step.condition} did not match #{outcome}"

    with :ok <- emit_terminal(on_output, step, position, 1, :skipped, nil, 0, message) do
      {:ok,
       %StepResult{
         name: step.name,
         status: :skipped,
         exit_code: nil,
         output: message,
         duration_ms: 0
       }}
    end
  end

  defp run_step(
         %Step{kind: :run} = step,
         position,
         specification,
         resource,
         on_output,
         cancel_requested
       ) do
    started = System.monotonic_time(:millisecond)

    args = [
      "exec",
      "--workdir",
      specification.workspace,
      resource,
      specification.shell,
      "-e",
      "-c",
      step.value
    ]

    abort_requested = fn ->
      execution_abort_request(specification, resource, cancel_requested)
    end

    case docker_stream(
           args,
           specification.timeout_ms,
           Map.values(specification.secrets),
           resource,
           abort_requested,
           &emit_output(on_output, step, position, started, &1, &2, &3)
         ) do
      {:ok, output, chunk_count} ->
        duration = System.monotonic_time(:millisecond) - started

        with :ok <-
               emit_terminal(on_output, step, position, chunk_count + 1, :succeeded, 0, duration) do
          {:ok, step_result(step, :succeeded, 0, output, started, [])}
        end

      {:error, %{exit_code: 124, output: output, chunk_count: chunk_count}} ->
        duration = System.monotonic_time(:millisecond) - started
        _ = emit_terminal(on_output, step, position, chunk_count + 1, :timed_out, nil, duration)
        {:failed, step_result(step, :timed_out, nil, output, started, []), :timeout}

      {:error, %{cancelled: true, output: output, chunk_count: chunk_count}} ->
        duration = System.monotonic_time(:millisecond) - started
        _ = emit_terminal(on_output, step, position, chunk_count + 1, :cancelled, nil, duration)
        {:cancelled, step_result(step, :failed, nil, output, started, [])}

      {:error,
       %{
         service_lost: _service_id,
         output: output,
         chunk_count: chunk_count
       }} ->
        duration = System.monotonic_time(:millisecond) - started

        _ =
          emit_terminal(on_output, step, position, chunk_count + 1, :failed, 1, duration, output)

        {:failed,
         step_result(step, :failed, 1, output, started, Map.values(specification.secrets)),
         :service_unavailable}

      {:error, %{exit_code: exit_code, output: output, chunk_count: chunk_count}} ->
        duration = System.monotonic_time(:millisecond) - started

        _ =
          emit_terminal(on_output, step, position, chunk_count + 1, :failed, exit_code, duration)

        {:failed, step_result(step, :failed, exit_code, output, started, []), :command_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_step(
         %Step{kind: :builtin, value: value} = step,
         position,
         specification,
         resource,
         callback,
         _cancel_requested
       ) do
    started = System.monotonic_time(:millisecond)

    result =
      case value do
        "cache/restore" ->
          restore_builtin(step, position, specification, resource, callback, :cache)

        "artifacts/download" ->
          restore_builtin(step, position, specification, resource, callback, :artifact)

        "cache/save" ->
          publish_builtin(step, position, specification, resource, callback, :cache)

        "artifacts/upload" ->
          publish_builtin(step, position, specification, resource, callback, :artifact)

        _ ->
          {:error, {:unsupported_builtin, value}}
      end

    case result do
      {:ok, message} ->
        duration = System.monotonic_time(:millisecond) - started
        :ok = emit_terminal(callback, step, position, 1, :succeeded, 0, duration)

        {:ok,
         step_result(
           step,
           :succeeded,
           0,
           message,
           started,
           Map.values(specification.secrets)
         )}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - started
        diagnostic = redact_and_truncate(inspect(reason), Map.values(specification.secrets))
        _ = emit_terminal(callback, step, position, 1, :failed, 1, duration, diagnostic)

        {:failed,
         step_result(
           step,
           :failed,
           1,
           diagnostic,
           started,
           []
         ), :command_failed}
    end
  end

  defp restore_builtin(step, position, specification, resource, callback, kind) do
    event = %{type: :builtin, phase: :restore, builtin: step.value, options: step.with}

    case callback.(event) do
      {:ok, :miss} when kind == :cache ->
        {:ok, "Cache miss: #{step.with["key"]}"}

      {:ok, %{content: content}} when is_binary(content) ->
        destination = if kind == :artifact, do: step.with["path"], else: "."
        restore_archive(content, position, specification, resource, destination)

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_builtin_response, other}}
    end
  end

  defp restore_archive(content, position, specification, resource, destination) do
    temporary = Path.join(System.tmp_dir!(), "robine-restore-#{Ecto.UUID.generate()}.tar.gz")
    container_path = "/var/tmp/robine-restore-#{position}.tar.gz"
    target = Path.join(specification.workspace, destination)

    try do
      with :ok <- SafeTar.validate_workspace_archive(content),
           :ok <- File.write(temporary, content, [:binary, :exclusive]),
           :ok <- File.chmod(temporary, 0o644),
           {:ok, _} <- docker(["cp", temporary, "#{resource}:#{container_path}"]),
           {:ok, _} <- docker(["exec", resource, "mkdir", "-p", target]),
           {:ok, _} <-
             docker(["exec", resource, "tar", "-xzf", container_path, "-C", target]) do
        {:ok, "Restored archive into #{destination}"}
      end
    after
      File.rm(temporary)
    end
  end

  defp publish_builtin(step, position, specification, resource, callback, kind) do
    container_path = "/var/tmp/robine-publish-#{position}.tar.gz"
    temporary = Path.join(System.tmp_dir!(), "robine-publish-#{Ecto.UUID.generate()}.tar.gz")
    paths = step.with["paths"]

    try do
      with {:ok, options} <- resolve_publish_options(step.with, kind),
           {:ok, _} <-
             docker([
               "exec",
               resource,
               "tar",
               "-czf",
               container_path,
               "-C",
               specification.workspace,
               "--"
               | paths
             ]),
           {:ok, _} <- docker(["cp", "#{resource}:#{container_path}", temporary]),
           {:ok, content} <- File.read(temporary),
           :ok <- SafeTar.validate_workspace_archive(content),
           {:ok, _metadata} <-
             callback.(%{
               type: :builtin,
               phase: :publish,
               builtin: step.value,
               options: options,
               content: content
             }),
           {:ok, _} <- docker(["exec", resource, "rm", "-f", container_path]) do
        label = if kind == :cache, do: options["key"], else: options["name"]
        {:ok, "Published #{kind} #{label}"}
      end
    after
      File.rm(temporary)
    end
  end

  defp resolve_publish_options(options, :artifact) do
    with {:ok, name} <- Robine.Execution.Domain.RunnerTemplate.resolve(options["name"]) do
      if Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/, name),
        do: {:ok, Map.put(options, "name", name)},
        else: {:error, :invalid_resolved_artifact_name}
    end
  end

  defp resolve_publish_options(options, :cache), do: {:ok, options}

  defp emit_output(on_output, step, position, started, chunk, chunk_index, stream) do
    on_output.(%{
      sequence: position * 1_000_000 + chunk_index,
      phase: :execution,
      step_position: position,
      step_name: step.name,
      status: :running,
      duration_ms: System.monotonic_time(:millisecond) - started,
      stream: stream,
      content: chunk
    })
  end

  defp emit_terminal(
         on_output,
         step,
         position,
         chunk_index,
         status,
         exit_code,
         duration,
         content \\ ""
       ) do
    on_output.(%{
      sequence: position * 1_000_000 + chunk_index,
      phase: :execution,
      step_position: position,
      step_name: step.name,
      status: status,
      condition: step.condition,
      exit_code: exit_code,
      duration_ms: duration,
      stream: :system,
      content: content
    })
  end

  defp step_result(step, status, exit_code, output, started, secret_values) do
    %StepResult{
      name: step.name,
      status: status,
      exit_code: exit_code,
      output: redact_and_truncate(output, secret_values),
      duration_ms: System.monotonic_time(:millisecond) - started
    }
  end

  defp docker_stream(args, timeout_ms, secret_values, resource, cancel_requested, on_chunk) do
    with executable when is_binary(executable) <- System.find_executable("docker"),
         {:ok, stdout_redactor} <- Redactor.new(secret_values),
         {:ok, stderr_redactor} <- Redactor.new(secret_values) do
      parent = self()
      task = Task.async(fn -> stream_command(parent, executable, args) end)
      task_pid = task.pid

      process =
        receive do
          {:stream_started, ^task_pid, process} -> process
        after
          5_000 -> raise "docker stream failed to start"
        end

      deadline = System.monotonic_time(:millisecond) + timeout_ms

      stream_receive(
        task,
        process,
        deadline,
        on_chunk,
        resource,
        cancel_requested,
        %{
          redactors: %{stdout: stdout_redactor, stderr: stderr_redactor},
          output: [],
          output_bytes: 0,
          truncated: false,
          chunk_count: 0
        }
      )
    else
      nil -> {:error, :docker_executable_unavailable}
      {:error, reason} -> {:error, {:redactor, reason}}
    end
  rescue
    error ->
      {:error,
       %{
         exit_code: nil,
         output: redact_and_truncate(Exception.message(error), secret_values),
         chunk_count: 0
       }}
  end

  defp stream_command(parent, executable, args) do
    {:ok, process} = Exile.Process.start_link([executable | args], stderr: :consume)
    send(parent, {:stream_started, self(), process})
    read_stream(process, parent)
  end

  defp read_stream(process, parent) do
    case Exile.Process.read_any(process, 64_000) do
      {:ok, {stream, data}} ->
        send(parent, {:stream_data, self(), stream, IO.iodata_to_binary(data)})

        receive do
          {:stream_ack, ^parent} -> read_stream(process, parent)
        end

      :eof ->
        {:ok, exit_status} = Exile.Process.await_exit(process, :infinity)
        send(parent, {:stream_exit, self(), exit_status})

      {:error, reason} ->
        _ = Exile.Process.await_exit(process, 1_000)
        send(parent, {:stream_error, self(), reason})
    end
  end

  defp stream_receive(task, process, deadline, on_chunk, resource, cancel_requested, state) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    task_pid = task.pid

    case cancel_requested.() do
      true ->
        cancel_running(task, process, resource, state)

      :cancelled ->
        cancel_running(task, process, resource, state)

      {:service_lost, service_id, diagnostic} ->
        service_lost_running(task, process, resource, state, service_id, diagnostic)

      false ->
        receive do
          {:stream_data, ^task_pid, stream, data} when stream in [:stdout, :stderr] ->
            redactor = Map.fetch!(state.redactors, stream)
            {emitted, redactor} = Redactor.push(redactor, data)
            updated = %{state | redactors: Map.put(state.redactors, stream, redactor)}

            case emit_stream_chunks(emitted, stream, on_chunk, updated) do
              {:ok, updated} ->
                send(task.pid, {:stream_ack, self()})

                stream_receive(
                  task,
                  process,
                  deadline,
                  on_chunk,
                  resource,
                  cancel_requested,
                  updated
                )

              {:error, reason} ->
                stop_stream(task, process)
                {:error, {:output_callback, reason}}
            end

          {:stream_exit, ^task_pid, exit_status} ->
            case finish_streams(on_chunk, state) do
              {:ok, updated} ->
                _ = Task.await(task, 1_000)
                stream_result(exit_status, updated)

              {:error, reason} ->
                {:error, {:output_callback, reason}}
            end

          {:stream_error, ^task_pid, reason} ->
            _ = Task.await(task, 1_000)
            {:error, %{exit_code: nil, output: inspect(reason), chunk_count: state.chunk_count}}

          {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
            {:error, %{exit_code: nil, output: inspect(reason), chunk_count: state.chunk_count}}
        after
          min(remaining, 250) ->
            if remaining <= 250,
              do: timeout_running(task, process, resource, state),
              else:
                stream_receive(
                  task,
                  process,
                  deadline,
                  on_chunk,
                  resource,
                  cancel_requested,
                  state
                )
        end
    end
  end

  defp execution_abort_request(%Specification{services: []}, _resource, cancel_requested),
    do: if(cancel_requested.(), do: :cancelled, else: false)

  defp execution_abort_request(specification, resource, cancel_requested) do
    if cancel_requested.() do
      :cancelled
    else
      Enum.find_value(specification.services, false, fn service ->
        name = service_resource_name(resource, service.id)

        case service_state(name) do
          {:ok, %{running: true}} ->
            false

          {:ok, %{running: false}} ->
            {:service_lost, service.id,
             service_diagnostic(name, service_secret_values(specification))}

          {:error, _reason} ->
            {:service_lost, service.id, "service state unavailable"}
        end
      end)
    end
  end

  defp service_lost_running(task, process, resource, state, service_id, diagnostic) do
    force_stop_running_container(resource)
    stop_stream(task, process)

    {:error,
     %{
       service_lost: service_id,
       output: "Service #{service_id} became unavailable\n#{diagnostic}",
       chunk_count: state.chunk_count
     }}
  end

  defp cancel_running(task, process, resource, state) do
    stop_running_container(resource)
    stop_stream(task, process)

    {:error,
     %{
       cancelled: true,
       output: rendered_output(state) <> "\njob cancelled",
       chunk_count: state.chunk_count
     }}
  end

  defp timeout_running(task, process, resource, state) do
    stop_running_container(resource)
    stop_stream(task, process)

    {:error,
     %{
       exit_code: 124,
       output: rendered_output(state) <> "\ncommand timed out",
       chunk_count: state.chunk_count
     }}
  end

  defp stop_running_container(resource) do
    grace_ms = Application.fetch_env!(:robine, :runner_cancellation_grace_ms)
    grace_seconds = max(div(grace_ms + 999, 1_000), 1)
    _ = docker(["stop", "--time", Integer.to_string(grace_seconds), resource], grace_ms + 5_000)
    :ok
  end

  defp force_stop_running_container(resource) do
    _ = docker(["kill", resource], 5_000)
    :ok
  end

  defp finish_streams(on_chunk, state) do
    Enum.reduce_while([:stdout, :stderr], {:ok, state}, fn stream, {:ok, current} ->
      tail = current.redactors |> Map.fetch!(stream) |> Redactor.finish()

      case emit_stream_chunks(tail, stream, on_chunk, current) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp emit_stream_chunks("", _stream, _on_chunk, state), do: {:ok, state}

  defp emit_stream_chunks(binary, stream, on_chunk, state) do
    binary
    |> chunk_binary(64_000, [])
    |> Enum.reduce_while({:ok, state}, fn chunk, {:ok, current} ->
      index = current.chunk_count + 1

      case on_chunk.(chunk, index, stream) do
        :ok -> {:cont, {:ok, current |> append_output(chunk) |> Map.put(:chunk_count, index)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp chunk_binary("", _limit, chunks), do: Enum.reverse(chunks)

  defp chunk_binary(binary, limit, chunks) when byte_size(binary) <= limit,
    do: Enum.reverse([binary | chunks])

  defp chunk_binary(binary, limit, chunks) do
    <<chunk::binary-size(^limit), rest::binary>> = binary
    chunk_binary(rest, limit, [chunk | chunks])
  end

  defp append_output(%{truncated: true} = state, _chunk), do: state

  defp append_output(state, chunk) do
    remaining = @output_limit - state.output_bytes

    cond do
      remaining <= 0 ->
        %{state | truncated: true}

      byte_size(chunk) <= remaining ->
        %{
          state
          | output: [chunk | state.output],
            output_bytes: state.output_bytes + byte_size(chunk)
        }

      true ->
        %{
          state
          | output: [binary_part(chunk, 0, remaining) | state.output],
            output_bytes: @output_limit,
            truncated: true
        }
    end
  end

  defp rendered_output(state) do
    output = state.output |> Enum.reverse() |> IO.iodata_to_binary()
    if state.truncated, do: output <> "\n[output truncated]", else: output
  end

  defp stream_result(0, state), do: {:ok, rendered_output(state), state.chunk_count}

  defp stream_result(exit_status, state),
    do:
      {:error,
       %{exit_code: exit_status, output: rendered_output(state), chunk_count: state.chunk_count}}

  defp stop_stream(task, process) do
    _ =
      try do
        Exile.Process.kill(process, :sigterm)
      catch
        :exit, _reason -> :ok
      end

    _ = Task.shutdown(task, 1_000)
    :ok
  end

  defp docker(args, timeout_ms \\ 30_000) do
    task = Task.async(fn -> System.cmd("docker", args, stderr_to_stdout: true) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, truncate_output(output)}

      {:ok, {output, exit_code}} ->
        {:error, %{exit_code: exit_code, output: truncate_output(output)}}

      nil ->
        {:error, %{exit_code: 124, output: "command timed out"}}
    end
  rescue
    error -> {:error, %{exit_code: nil, output: Exception.message(error)}}
  end

  defp cleanup(specification, resource, volume, network) do
    results =
      [docker(["rm", "--force", "--volumes", resource])] ++
        Enum.map(specification.services, fn service ->
          docker([
            "rm",
            "--force",
            "--volumes",
            service_resource_name(resource, service.id)
          ])
        end) ++
        [docker(["volume", "rm", "--force", volume])] ++
        if(network, do: [docker(["network", "rm", network])], else: [])

    normalized = Enum.map(results, &ignorable_cleanup/1)
    if Enum.all?(normalized, &(&1 == :ok)), do: nil, else: inspect(normalized)
  end

  defp ignorable_cleanup({:ok, _output}), do: :ok
  defp ignorable_cleanup({:error, %{exit_code: 1}}), do: :ok
  defp ignorable_cleanup(error), do: error

  defp environment_args(environment) do
    environment
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, value} -> ["--env", "#{key}=#{value}"] end)
  end

  defp service_user_args(nil), do: []
  defp service_user_args(user), do: ["--user", user]

  defp resource_name(attempt_id) do
    suffix =
      :crypto.hash(:sha256, attempt_id) |> Base.encode16(case: :lower) |> binary_part(0, 20)

    "robine-#{suffix}"
  end

  defp service_resource_name(resource, service_id), do: "#{resource}-svc-#{service_id}"

  defp service_secret_values(specification) do
    Map.values(specification.secrets) ++
      Enum.flat_map(specification.services, &Map.values(&1.secret_env))
  end

  defp label(specification), do: "#{@attempt_label}=#{specification.attempt_id}"

  defp truncate_output(output) when byte_size(output) <= @output_limit, do: output

  defp truncate_output(output),
    do: binary_part(output, 0, @output_limit) <> "\n[output truncated]"

  defp redact_and_truncate(output, []), do: truncate_output(output)

  defp redact_and_truncate(output, secret_values) do
    case Robine.Secrets.redact_output(%{output: output, values: secret_values}) do
      {:ok, redacted} -> truncate_output(redacted)
      {:error, _reason} -> "[output unavailable: redaction failed]"
    end
  end

  defp redact_error({:error, %{output: output} = reason}, secret_values) do
    {:error, %{reason | output: redact_and_truncate(output, secret_values)}}
  end
end
