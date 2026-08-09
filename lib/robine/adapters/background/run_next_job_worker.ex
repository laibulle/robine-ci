defmodule Robine.Adapters.Background.RunNextJobWorker do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 5]

  alias Robine.Execution
  alias Robine.Execution.Contracts.{Specification, Step}
  alias Robine.Execution.Domain.CacheKey
  alias Robine.Adapters.Background.RunnerControl
  alias Robine.Pipelines
  alias Robine.Repositories
  alias Robine.Runtime.Dependencies
  alias Robine.Secrets
  alias Robine.Storage

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    context =
      Dependencies.context(
        %{id: "system:local-runner", role: :administrator},
        "local-runner:#{Ecto.UUID.generate()}"
      )

    runner_control = Application.fetch_env!(:robine, :runner_control)

    case Pipelines.claim_next_job(
           %{lease_seconds: Keyword.fetch!(runner_control, :lease_seconds)},
           context
         ) do
      {:ok, attempt} -> execute(attempt, context)
      {:error, :none} -> :ok
      {:error, :capacity} -> {:snooze, 1}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute(attempt, context) do
    with {:ok, _preparing} <- record(attempt, 1, :preparing, nil, context),
         {:ok, raw_specification} <-
           Pipelines.job_execution(%{idempotency_token: attempt.idempotency_token}, context),
         {:ok, source_path} <- materialize_source(raw_specification, context),
         {:ok, specification} <- specification(raw_specification, context, source_path) do
      try do
        execute_specification(attempt, raw_specification, specification, context)
      after
        cleanup_source(source_path)
      end
    else
      {:error, reason} ->
        _ = record(attempt, 3, :failed, :system_failure, context)
        {:error, reason}
    end
  end

  defp execute_specification(attempt, raw, specification, context) do
    with {:ok, _running} <- record(attempt, 2, :running, nil, context),
         {:ok, result} <- run_with_control(attempt, raw, specification, context),
         {:ok, _terminal} <- record_result(attempt, result, context) do
      enqueue_next()
    else
      {:error, reason} ->
        _ = record(attempt, 3, :failed, :system_failure, context)
        {:error, reason}
    end
  end

  defp run_with_control(attempt, raw, specification, context) do
    with {:ok, control} <- RunnerControl.start(attempt.idempotency_token, context) do
      try do
        Execution.run_job(
          %{
            specification: specification,
            on_output: &persist_log_event(attempt.id, &1, context),
            on_builtin: &handle_builtin(&1, raw, attempt, context),
            cancel_requested: fn -> control_cancellation_requested?(control, attempt, context) end
          },
          context
        )
      after
        RunnerControl.stop(control)
      end
    end
  end

  defp specification(raw, context, source_path) do
    with image when is_binary(image) <- raw["image"],
         steps when is_list(steps) and steps != [] <- raw["steps"],
         steps = Enum.reject(steps, &checkout_step?/1),
         true <- steps != [],
         {:ok, secret_values} <- resolve_secrets(raw, context),
         {:ok, normalized_steps} <- resolve_steps(steps, source_path) do
      {:ok,
       %Specification{
         version: 1,
         attempt_id: raw["attempt_id"],
         image: image,
         workspace: "/workspace",
         shell: raw["shell"] || "/bin/sh",
         timeout_ms: raw["timeout_ms"] || 1_200_000,
         source_path: source_path,
         env: raw["env"] || %{},
         secrets: secret_values,
         metadata: %{"idempotency_token" => raw["idempotency_token"]},
         steps: normalized_steps
       }}
    else
      _ -> {:error, :invalid_persisted_execution_specification}
    end
  end

  defp materialize_source(%{"steps" => steps} = raw, context) when is_list(steps) do
    if Enum.any?(steps, &checkout_step?/1) do
      with {:ok, source} <-
             Repositories.fetch_source(
               %{repository_id: raw["repository_id"], commit_sha: raw["commit_sha"]},
               context
             ) do
        write_source(source.files)
      end
    else
      {:ok, nil}
    end
  end

  defp materialize_source(_raw, _context), do: {:ok, nil}

  defp write_source(files) do
    directory = Path.join(System.tmp_dir!(), "robine-source-#{Ecto.UUID.generate()}")

    with :ok <- File.mkdir(directory),
         :ok <- write_source_files(directory, files) do
      {:ok, directory}
    else
      {:error, reason} ->
        File.rm_rf(directory)
        {:error, {:source_materialization, reason}}
    end
  end

  defp write_source_files(directory, files) do
    Enum.reduce_while(files, :ok, fn {relative, content}, :ok ->
      destination = Path.join(directory, relative)

      with :ok <- File.mkdir_p(Path.dirname(destination)),
           :ok <- File.write(destination, content, [:binary, :exclusive]) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp cleanup_source(nil), do: :ok
  defp cleanup_source(directory), do: File.rm_rf(directory)

  defp checkout_step?(%{"kind" => kind, "value" => "checkout"})
       when kind in [:builtin, "builtin"],
       do: true

  defp checkout_step?(_step), do: false

  defp resolve_secrets(%{"secret_names" => []}, _context), do: {:ok, %{}}

  defp resolve_secrets(%{"secret_names" => names} = raw, context) when is_list(names) do
    Secrets.resolve_secrets(%{repository_id: raw["repository_id"], names: names}, context)
  end

  defp resolve_secrets(_raw, _context), do: {:ok, %{}}

  defp step(raw) do
    %Step{
      name: raw["name"],
      kind: kind(raw["kind"]),
      value: raw["value"],
      with: raw["with"] || %{}
    }
  end

  defp resolve_steps(steps, source_path) do
    Enum.reduce_while(steps, {:ok, []}, fn raw, {:ok, resolved} ->
      step = step(raw)

      case resolve_step(step, source_path) do
        {:ok, value} -> {:cont, {:ok, [value | resolved]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      error -> error
    end
  end

  defp resolve_step(%Step{value: value, with: %{"key" => key}} = step, source_path)
       when value in ["cache/restore", "cache/save"] and is_binary(source_path) do
    case CacheKey.resolve(key, source_path) do
      {:ok, resolved} -> {:ok, %{step | with: Map.put(step.with, "key", resolved)}}
      error -> error
    end
  end

  defp resolve_step(%Step{value: value, with: %{"key" => key}} = step, nil)
       when value in ["cache/restore", "cache/save"] do
    if String.contains?(key, "${{"),
      do: {:error, {:cache_checksum, :checkout_required}},
      else: {:ok, step}
  end

  defp resolve_step(step, _source_path), do: {:ok, step}

  defp kind(:run), do: :run
  defp kind("run"), do: :run
  defp kind(:builtin), do: :builtin
  defp kind("builtin"), do: :builtin
  defp kind(_unknown), do: :invalid

  defp record_result(attempt, %{status: :succeeded}, context),
    do: record(attempt, 3, :succeeded, nil, context)

  defp record_result(attempt, %{status: :failed, reason: reason}, context),
    do: record(attempt, 3, :failed, reason, context)

  defp record_result(attempt, %{status: :cancelled}, context),
    do: record(attempt, 3, :cancelled, :cancelled, context)

  defp persist_log_event(attempt_id, event, context),
    do: Pipelines.append_log_event(Map.put(event, :attempt_id, attempt_id), context)

  defp cancellation_requested?(token, context) do
    case Pipelines.cancellation_requested(%{idempotency_token: token}, context) do
      {:ok, requested?} -> requested?
      {:error, _reason} -> false
    end
  end

  defp control_cancellation_requested?(control, attempt, context) do
    RunnerControl.cancellation_requested?(control)
  catch
    :exit, _reason -> cancellation_requested?(attempt.idempotency_token, context)
  end

  defp handle_builtin(
         %{phase: :restore, builtin: "cache/restore", options: %{"key" => key}},
         raw,
         _attempt,
         context
       ) do
    Storage.restore_cache(%{repository_id: raw["repository_id"], key: key}, context)
  end

  defp handle_builtin(
         %{
           phase: :publish,
           builtin: "cache/save",
           options: %{"key" => key},
           content: content
         },
         raw,
         _attempt,
         context
       ) do
    Storage.save_cache(
      %{repository_id: raw["repository_id"], key: key, content: content},
      context
    )
  end

  defp handle_builtin(
         %{
           phase: :publish,
           builtin: "artifacts/upload",
           options: %{"name" => name, "retention-days" => days},
           content: content
         },
         raw,
         attempt,
         context
       ) do
    Storage.upload_artifact(
      %{
        repository_id: raw["repository_id"],
        attempt_id: attempt.id,
        name: name,
        content: content,
        retention_seconds: days * 86_400
      },
      context
    )
  end

  defp handle_builtin(
         %{
           phase: :restore,
           builtin: "artifacts/download",
           options: %{"name" => name, "from" => from_job}
         },
         raw,
         _attempt,
         context
       ) do
    Storage.download_dependency_artifact(
      %{
        pipeline_id: raw["pipeline_id"],
        from_job: from_job,
        name: name,
        needs: raw["needs"]
      },
      context
    )
  end

  defp handle_builtin(event, _raw, _attempt, _context),
    do: {:error, {:unsupported_builtin_event, Map.drop(event, [:content])}}

  defp record(attempt, sequence, status, reason, context) do
    Pipelines.record_runner_event(
      %{
        idempotency_token: attempt.idempotency_token,
        sequence: sequence,
        status: status,
        reason: reason
      },
      context
    )
  end

  defp enqueue_next do
    case Oban.insert(new(%{})) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
