defmodule Robine.Adapters.Execution.DockerRunner do
  @moduledoc false
  @behaviour Robine.Execution.Ports.Runner

  alias Robine.Execution.Contracts.{Result, Specification, Step, StepResult}
  alias Robine.Adapters.Archive.SafeTar
  alias Robine.Secrets.Domain.Redactor

  @output_limit 10_000_000
  @attempt_label "io.robine.attempt"

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

    with :ok <- prepare_image(specification, on_output) do
      case provision(specification, resource, volume) do
        :ok ->
          run_owned(specification, resource, volume, started_at, on_output, cancel_requested)

        {:error, :duplicate_attempt} ->
          {:error, {:docker, :duplicate_attempt}}

        {:error, reason} ->
          _cleanup_warning = cleanup(resource, volume)
          {:error, {:docker, reason}}
      end
    end
  end

  defp run_owned(specification, resource, volume, started_at, on_output, cancel_requested) do
    with :ok <- copy_source(specification.source_path, resource, specification.workspace),
         :ok <- start_container(resource, specification.shell),
         :ok <- ensure_shell(resource, specification.shell),
         {:ok, step_results} <-
           run_steps(specification, resource, on_output, cancel_requested) do
      cleanup_warning = cleanup(resource, volume)

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
        cleanup_warning = cleanup(resource, volume)

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
        cleanup_warning = cleanup(resource, volume)

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
        _cleanup_warning = cleanup(resource, volume)
        {:error, {:docker, reason}}
    end
  end

  defp provision(specification, resource, volume) do
    with {:ok, _output} <-
           docker(["volume", "create", "--label", label(specification), volume]),
         {:ok, _output} <- create_container(specification, resource, volume) do
      :ok
    end
  end

  @impl true
  def reconcile_resources(active_attempt_ids) do
    active = MapSet.new(active_attempt_ids)

    with {:ok, containers} <- labeled_resources(:container),
         {:ok, removed_containers} <- remove_orphans(containers, active, :container),
         {:ok, volumes} <- labeled_resources(:volume),
         {:ok, removed_volumes} <- remove_orphans(volumes, active, :volume) do
      {:ok, %{containers_removed: removed_containers, volumes_removed: removed_volumes}}
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
          :container -> ["rm", "--force", resource.name]
          :volume -> ["volume", "rm", "--force", resource.name]
        end

      case docker(args) do
        {:ok, _output} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, {:orphan_cleanup, type, reason}}}
      end
    end)
  end

  defp prepare_image(specification, callback) do
    started = System.monotonic_time(:millisecond)

    with :ok <- emit_phase(callback, 1, :running, started, "Acquiring #{specification.image}"),
         {:ok, detail} <- acquire_image(specification.image, specification.timeout_ms),
         :ok <- emit_phase(callback, 2, :succeeded, started, detail) do
      :ok
    else
      {:error, reason} = error ->
        _ = emit_phase(callback, 2, :failed, started, "Image acquisition failed")

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

  defp emit_phase(callback, sequence, status, started, content) do
    callback.(%{
      sequence: sequence,
      phase: :image_acquisition,
      step_position: 0,
      step_name: "Image acquisition",
      status: status,
      exit_code: if(status == :failed, do: 1, else: nil),
      duration_ms: System.monotonic_time(:millisecond) - started,
      content: content
    })
  end

  defp create_container(specification, resource, volume) do
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
        "bridge",
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
    |> Enum.reduce_while({:ok, []}, fn {step, position}, {:ok, results} ->
      case run_step(step, position, specification, resource, on_output, cancel_requested) do
        {:ok, result} -> {:cont, {:ok, results ++ [result]}}
        {:failed, result, reason} -> {:halt, {:step_failed, results ++ [result], reason}}
        {:cancelled, result} -> {:halt, {:step_cancelled, results ++ [result]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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

    case docker_stream(
           args,
           specification.timeout_ms,
           Map.values(specification.secrets),
           resource,
           cancel_requested,
           &emit_output(on_output, step, position, started, &1, &2)
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
        _ = emit_terminal(callback, step, position, 1, :failed, 1, duration)

        {:failed,
         step_result(
           step,
           :failed,
           1,
           inspect(reason),
           started,
           Map.values(specification.secrets)
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
      with {:ok, _} <-
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
               options: step.with,
               content: content
             }),
           {:ok, _} <- docker(["exec", resource, "rm", "-f", container_path]) do
        label = if kind == :cache, do: step.with["key"], else: step.with["name"]
        {:ok, "Published #{kind} #{label}"}
      end
    after
      File.rm(temporary)
    end
  end

  defp emit_output(on_output, step, position, started, chunk, chunk_index) do
    on_output.(%{
      sequence: position * 1_000_000 + chunk_index,
      phase: :execution,
      step_position: position,
      step_name: step.name,
      status: :running,
      duration_ms: System.monotonic_time(:millisecond) - started,
      content: chunk
    })
  end

  defp emit_terminal(on_output, step, position, chunk_index, status, exit_code, duration) do
    on_output.(%{
      sequence: position * 1_000_000 + chunk_index,
      phase: :execution,
      step_position: position,
      step_name: step.name,
      status: status,
      exit_code: exit_code,
      duration_ms: duration,
      content: ""
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
         {:ok, redactor} <- Redactor.new(secret_values) do
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: args
        ])

      deadline = System.monotonic_time(:millisecond) + timeout_ms

      stream_receive(
        port,
        deadline,
        on_chunk,
        resource,
        cancel_requested,
        %{
          redactor: redactor,
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

  defp stream_receive(port, deadline, on_chunk, resource, cancel_requested, state) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if cancel_requested.() do
      cancel_running(port, resource, state)
    else
      receive do
        {^port, {:data, data}} ->
          {emitted, redactor} = Redactor.push(state.redactor, data)

          case emit_stream_chunks(emitted, on_chunk, %{state | redactor: redactor}) do
            {:ok, updated} ->
              stream_receive(port, deadline, on_chunk, resource, cancel_requested, updated)

            {:error, reason} ->
              close_port(port, {:error, {:output_callback, reason}})
          end

        {^port, {:exit_status, exit_status}} ->
          tail = Redactor.finish(state.redactor)

          case emit_stream_chunks(tail, on_chunk, state) do
            {:ok, updated} -> stream_result(exit_status, updated)
            {:error, reason} -> {:error, {:output_callback, reason}}
          end
      after
        min(remaining, 250) ->
          if remaining <= 250,
            do: timeout_running(port, state),
            else: stream_receive(port, deadline, on_chunk, resource, cancel_requested, state)
      end
    end
  end

  defp cancel_running(port, resource, state) do
    grace_ms = Application.fetch_env!(:robine, :runner_cancellation_grace_ms)
    grace_seconds = max(div(grace_ms + 999, 1_000), 1)
    _ = docker(["stop", "--time", Integer.to_string(grace_seconds), resource], grace_ms + 5_000)

    close_port(
      port,
      {:error,
       %{
         cancelled: true,
         output: rendered_output(state) <> "\njob cancelled",
         chunk_count: state.chunk_count
       }}
    )
  end

  defp timeout_running(port, state) do
    close_port(
      port,
      {:error,
       %{
         exit_code: 124,
         output: rendered_output(state) <> "\ncommand timed out",
         chunk_count: state.chunk_count
       }}
    )
  end

  defp emit_stream_chunks("", _on_chunk, state), do: {:ok, state}

  defp emit_stream_chunks(binary, on_chunk, state) do
    binary
    |> chunk_binary(64_000, [])
    |> Enum.reduce_while({:ok, state}, fn chunk, {:ok, current} ->
      index = current.chunk_count + 1

      case on_chunk.(chunk, index) do
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

  defp close_port(port, result) do
    Port.close(port)
    result
  rescue
    _error -> result
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

  defp cleanup(resource, volume) do
    container_result = docker(["rm", "--force", resource])
    volume_result = docker(["volume", "rm", "--force", volume])

    case {ignorable_cleanup(container_result), ignorable_cleanup(volume_result)} do
      {:ok, :ok} -> nil
      other -> inspect(other)
    end
  end

  defp ignorable_cleanup({:ok, _output}), do: :ok
  defp ignorable_cleanup({:error, %{exit_code: 1}}), do: :ok
  defp ignorable_cleanup(error), do: error

  defp environment_args(environment) do
    environment
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, value} -> ["--env", "#{key}=#{value}"] end)
  end

  defp resource_name(attempt_id) do
    suffix =
      :crypto.hash(:sha256, attempt_id) |> Base.encode16(case: :lower) |> binary_part(0, 20)

    "robine-#{suffix}"
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
