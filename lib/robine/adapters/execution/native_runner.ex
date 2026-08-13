defmodule Robine.Adapters.Execution.NativeRunner do
  @moduledoc "Executes trusted CI commands directly on a dedicated Unix host."
  @behaviour Robine.Execution.Ports.Runner

  alias Robine.Adapters.Archive.SafeTar
  alias Robine.Execution.Contracts.{Result, Specification, Step, StepResult}
  alias Robine.Execution.Domain.RunnerTemplate
  alias Robine.Secrets.Domain.Redactor

  @output_limit 10_000_000

  @impl true
  def run(%Specification{} = specification, callback, cancel_requested) do
    started_at = DateTime.utc_now()

    root =
      Path.join(
        System.tmp_dir!(),
        "robine-native-#{safe_id(specification.attempt_id)}-#{Ecto.UUID.generate()}"
      )

    workspace = Path.join(root, "workspace")

    try do
      with :ok <- reject_unsupported(specification),
           :ok <- File.mkdir(root),
           :ok <- File.chmod(root, 0o700),
           :ok <- materialize_source(specification.source_path, workspace),
           {:ok, steps, status, reason} <-
             run_steps(specification, workspace, callback, cancel_requested) do
        {:ok,
         %Result{
           attempt_id: specification.attempt_id,
           status: status,
           reason: reason,
           steps: steps,
           started_at: started_at,
           finished_at: DateTime.utc_now()
         }}
      end
    after
      File.rm_rf(root)
    end
  end

  @impl true
  def reconcile_resources(_active_attempt_ids), do: {:ok, %{directories_removed: 0}}

  defp reject_unsupported(%Specification{services: [_ | _]}),
    do: {:error, {:native, :service_containers_unsupported}}

  defp reject_unsupported(%Specification{}), do: :ok

  defp materialize_source(nil, workspace), do: File.mkdir(workspace)

  defp materialize_source(source, workspace) do
    with :ok <- validate_tree(source),
         {:ok, _entries} <- File.cp_r(source, workspace) do
      :ok
    end
  end

  defp validate_tree(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        with {:ok, entries} <- File.ls(path) do
          Enum.reduce_while(entries, :ok, fn entry, :ok ->
            case validate_tree(Path.join(path, entry)) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        end

      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, _unsupported} ->
        {:error, {:native, :unsafe_source_tree}}

      {:error, reason} ->
        {:error, {:native, reason}}
    end
  end

  defp run_steps(specification, workspace, callback, cancel_requested) do
    specification.steps
    |> Enum.with_index(1)
    |> Enum.reduce_while({[], nil}, fn {step, position}, {results, first_failure} ->
      if condition_matches?(step.condition, first_failure) do
        case run_step(step, position, specification, workspace, callback, cancel_requested) do
          {:ok, result} -> {:cont, {results ++ [result], first_failure}}
          {:failed, result, reason} -> {:cont, {results ++ [result], first_failure || reason}}
          {:cancelled, result} -> {:halt, {:cancelled, results ++ [result]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        result = %StepResult{
          name: step.name,
          status: :skipped,
          exit_code: nil,
          output: "",
          duration_ms: 0
        }

        emit(callback, position, step.name, :skipped, nil, 0, "")
        {:cont, {results ++ [result], first_failure}}
      end
    end)
    |> case do
      {:cancelled, results} -> {:ok, results, :cancelled, :cancelled}
      {:error, reason} -> {:error, reason}
      {results, nil} -> {:ok, results, :succeeded, nil}
      {results, reason} -> {:ok, results, :failed, reason}
    end
  end

  defp run_step(
         %Step{kind: :run} = step,
         position,
         specification,
         workspace,
         callback,
         cancel_requested
       ) do
    started = System.monotonic_time(:millisecond)
    env = Map.merge(specification.env, specification.secrets) |> Map.to_list()
    emit(callback, position, step.name, :running, nil, 0, "")

    case command(
           specification.shell,
           step.value,
           workspace,
           env,
           Map.values(specification.secrets),
           specification.timeout_ms,
           cancel_requested,
           &emit(callback, position, step.name, :running, nil, elapsed(started), &1)
         ) do
      {:ok, exit_code, output} ->
        duration = elapsed(started)
        status = if exit_code == 0, do: :succeeded, else: :failed
        emit(callback, position, step.name, status, exit_code, duration, "")

        result = %StepResult{
          name: step.name,
          status: status,
          exit_code: exit_code,
          output: output,
          duration_ms: duration
        }

        if exit_code == 0, do: {:ok, result}, else: {:failed, result, :command_failed}

      {:cancelled, output} ->
        duration = elapsed(started)
        emit(callback, position, step.name, :cancelled, nil, duration, "")

        {:cancelled,
         %StepResult{
           name: step.name,
           status: :failed,
           exit_code: nil,
           output: output,
           duration_ms: duration
         }}

      {:timeout, output} ->
        duration = elapsed(started)
        emit(callback, position, step.name, :timed_out, nil, duration, "")

        {:failed,
         %StepResult{
           name: step.name,
           status: :timed_out,
           exit_code: nil,
           output: output,
           duration_ms: duration
         }, :timeout}

      {:error, reason} ->
        {:error, {:native, reason}}
    end
  end

  defp run_step(
         %Step{kind: :builtin} = step,
         position,
         _specification,
         workspace,
         callback,
         _cancel_requested
       ) do
    started = System.monotonic_time(:millisecond)
    emit(callback, position, step.name, :running, nil, 0, "")

    result =
      case step.value do
        "cache/restore" -> restore_builtin(step, workspace, callback, :cache)
        "artifacts/download" -> restore_builtin(step, workspace, callback, :artifact)
        "cache/save" -> publish_builtin(step, workspace, callback, :cache)
        "artifacts/upload" -> publish_builtin(step, workspace, callback, :artifact)
        unsupported -> {:error, {:unsupported_builtin, unsupported}}
      end

    duration = elapsed(started)

    case result do
      {:ok, message} ->
        emit(callback, position, step.name, :succeeded, 0, duration, "")

        {:ok,
         %StepResult{
           name: step.name,
           status: :succeeded,
           exit_code: 0,
           output: message,
           duration_ms: duration
         }}

      {:error, reason} ->
        diagnostic = inspect(reason)
        emit(callback, position, step.name, :failed, 1, duration, diagnostic)

        {:failed,
         %StepResult{
           name: step.name,
           status: :failed,
           exit_code: 1,
           output: diagnostic,
           duration_ms: duration
         }, :command_failed}
    end
  end

  defp restore_builtin(step, workspace, callback, kind) do
    event = %{type: :builtin, phase: :restore, builtin: step.value, options: step.with}

    case callback.(event) do
      {:ok, :miss} when kind == :cache ->
        {:ok, "Cache miss: #{step.with["key"]}"}

      {:ok, %{content: content}} when is_binary(content) ->
        destination = if kind == :artifact, do: step.with["path"], else: "."
        restore_archive(content, workspace, destination)

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_builtin_response, other}}
    end
  end

  defp restore_archive(content, workspace, destination) do
    temporary =
      Path.join(System.tmp_dir!(), "robine-native-restore-#{Ecto.UUID.generate()}.tar.gz")

    try do
      with :ok <- SafeTar.validate_workspace_archive(content),
           {:ok, target} <- workspace_target(workspace, destination),
           :ok <- File.mkdir_p(target),
           :ok <- File.write(temporary, content, [:binary, :exclusive]),
           {:ok, _output} <- tar(["-xzf", temporary, "-C", target]) do
        {:ok, "Restored archive into #{destination}"}
      end
    after
      File.rm(temporary)
    end
  end

  defp publish_builtin(step, workspace, callback, kind) do
    temporary =
      Path.join(System.tmp_dir!(), "robine-native-publish-#{Ecto.UUID.generate()}.tar.gz")

    try do
      with {:ok, options} <- resolve_publish_options(step.with, kind),
           {:ok, paths} <- publish_paths(options["paths"], workspace),
           {:ok, _output} <- tar(["-czf", temporary, "-C", workspace, "--" | paths]),
           {:ok, content} <- File.read(temporary),
           :ok <- SafeTar.validate_workspace_archive(content),
           {:ok, _metadata} <-
             callback.(%{
               type: :builtin,
               phase: :publish,
               builtin: step.value,
               options: options,
               content: content
             }) do
        label = if kind == :cache, do: options["key"], else: options["name"]
        {:ok, "Published #{kind} #{label}"}
      end
    after
      File.rm(temporary)
    end
  end

  defp resolve_publish_options(options, :artifact) do
    with {:ok, name} <- RunnerTemplate.resolve(options["name"]) do
      if Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/, name),
        do: {:ok, Map.put(options, "name", name)},
        else: {:error, :invalid_resolved_artifact_name}
    end
  end

  defp resolve_publish_options(options, :cache), do: {:ok, options}

  defp publish_paths(paths, workspace) when is_list(paths) and paths != [] do
    if Enum.all?(paths, fn path -> match?({:ok, _target}, workspace_target(workspace, path)) end),
      do: {:ok, paths},
      else: {:error, :unsafe_builtin_path}
  end

  defp publish_paths(_paths, _workspace), do: {:error, :invalid_builtin_paths}

  defp workspace_target(workspace, destination) when is_binary(destination) do
    target = Path.expand(destination, workspace)
    expanded_workspace = Path.expand(workspace)

    if target == expanded_workspace or String.starts_with?(target, expanded_workspace <> "/"),
      do: {:ok, target},
      else: {:error, :unsafe_builtin_path}
  end

  defp workspace_target(_workspace, _destination), do: {:error, :unsafe_builtin_path}

  defp tar(arguments) do
    case System.find_executable("tar") do
      nil ->
        {:error, :tar_unavailable}

      executable ->
        task = Task.async(fn -> System.cmd(executable, arguments, stderr_to_stdout: true) end)

        case Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, 0}} ->
            {:ok, output}

          {:ok, {output, status}} ->
            {:error, {:tar_failed, status, String.slice(output, 0, 4_096)}}

          nil ->
            {:error, :tar_timeout}
        end
    end
  end

  defp command(shell, script, workspace, env, secrets, timeout_ms, cancel_requested, on_chunk) do
    owner = self()
    task = Task.async(fn -> stream_command(owner, shell, script, workspace, env) end)
    task_pid = task.pid

    with {:ok, redactor} <- Redactor.new(secrets) do
      receive do
        {:native_started, ^task_pid, process} ->
          await_command(
            task,
            process,
            System.monotonic_time(:millisecond) + timeout_ms,
            cancel_requested,
            on_chunk,
            [],
            0,
            redactor
          )

        {:native_start_error, ^task_pid, reason} ->
          {:error, reason}
      after
        5_000 ->
          Task.shutdown(task, :brutal_kill)
          {:error, :process_start_timeout}
      end
    end
  end

  defp stream_command(owner, shell, script, workspace, env) do
    case Exile.Process.start_link([shell, "-e", "-c", script],
           cd: workspace,
           env: env,
           stderr: :consume
         ) do
      {:ok, process} ->
        send(owner, {:native_started, self(), process})
        read_command(process, owner)

      {:error, reason} ->
        send(owner, {:native_start_error, self(), reason})
    end
  end

  defp read_command(process, owner) do
    case Exile.Process.read_any(process, 64_000) do
      {:ok, {_stream, data}} ->
        send(owner, {:native_data, self(), IO.iodata_to_binary(data)})
        receive do: ({:native_ack, ^owner} -> read_command(process, owner))

      :eof ->
        send(owner, {:native_exit, self(), Exile.Process.await_exit(process, :infinity)})

      {:error, reason} ->
        send(owner, {:native_read_error, self(), reason})
    end
  end

  defp await_command(task, process, deadline, cancel_requested, on_chunk, chunks, bytes, redactor) do
    cond do
      cancel_requested.() ->
        stop(task, process, {:cancelled, IO.iodata_to_binary(Enum.reverse(chunks))})

      System.monotonic_time(:millisecond) >= deadline ->
        stop(task, process, {:timeout, IO.iodata_to_binary(Enum.reverse(chunks))})

      true ->
        receive do
          {:native_data, pid, data} when pid == task.pid ->
            {data, redactor} = Redactor.push(redactor, data)
            remaining = max(@output_limit - bytes, 0)

            kept =
              if byte_size(data) <= remaining, do: data, else: binary_part(data, 0, remaining)

            on_chunk.(kept)
            send(pid, {:native_ack, self()})

            await_command(
              task,
              process,
              deadline,
              cancel_requested,
              on_chunk,
              [kept | chunks],
              bytes + byte_size(kept),
              redactor
            )

          {:native_exit, pid, {:ok, status}} when pid == task.pid ->
            Process.demonitor(task.ref, [:flush])
            tail = Redactor.finish(redactor)
            on_chunk.(tail)
            {:ok, status, IO.iodata_to_binary(Enum.reverse([tail | chunks]))}

          {:native_read_error, pid, reason} when pid == task.pid ->
            {:error, reason}
        after
          50 ->
            await_command(
              task,
              process,
              deadline,
              cancel_requested,
              on_chunk,
              chunks,
              bytes,
              redactor
            )
        end
    end
  end

  defp stop(task, process, result) do
    _ = Exile.Process.kill(process, :sigterm)
    _ = Task.shutdown(task, :brutal_kill)
    result
  end

  defp emit(callback, position, name, status, exit_code, duration, content) do
    callback.(%{
      sequence: System.unique_integer([:positive]),
      phase: :step_execution,
      step_position: position,
      step_name: name,
      status: status,
      exit_code: exit_code,
      duration_ms: duration,
      stream: :combined,
      content: content
    })

    :ok
  end

  defp condition_matches?(:success, nil), do: true
  defp condition_matches?(:success, _), do: false
  defp condition_matches?(:failure, nil), do: false
  defp condition_matches?(:failure, _), do: true
  defp condition_matches?(:always, _), do: true
  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
  defp safe_id(id), do: String.replace(id, ~r/[^a-zA-Z0-9_.-]/, "-")
end
