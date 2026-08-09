defmodule Robine.Adapters.Background.RunNextJobWorker do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 5]

  alias Robine.Execution
  alias Robine.Adapters.Background.RunnerControl
  alias Robine.Observability.Log
  alias Robine.Pipelines
  alias Robine.Repositories
  alias Robine.Runtime.Dependencies
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
      {:ok, attempt} ->
        attempt_context = %{context | correlation_id: "attempt:#{attempt.id}"}

        Log.event(:info, "runner.attempt.claimed", %{
          correlation_id: attempt_context.correlation_id,
          attempt_id: attempt.id,
          runner_id: "local",
          outcome: :claimed
        })

        execute(attempt, attempt_context)
      {:error, :none} -> :ok
      {:error, :capacity} -> {:snooze, 1}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute(attempt, context) do
    with {:ok, _preparing} <- record(attempt, 1, :preparing, nil, context),
         {:ok, raw_specification} <-
           Pipelines.job_execution(%{idempotency_token: attempt.idempotency_token}, context),
         :ok <- log_execution_start(attempt, raw_specification, context),
         {:ok, source_path} <- materialize_source(raw_specification, context),
         {:ok, specification} <-
           Execution.build_ci_specification(
             %{persisted: raw_specification, source_path: source_path},
             context
           ) do
      try do
        execute_specification(attempt, raw_specification, specification, context)
      after
        cleanup_source(source_path)
      end
    else
      {:error, reason} ->
        _ = record(attempt, 3, :failed, :system_failure, context)

        Log.event(:error, "runner.attempt.completed", %{
          correlation_id: context.correlation_id,
          attempt_id: attempt.id,
          runner_id: "local",
          outcome: :system_failure
        })

        {:error, reason}
    end
  end

  defp execute_specification(attempt, raw, specification, context) do
    execution_result =
      with {:ok, _running} <- record(attempt, 2, :running, nil, context),
           {:ok, result} <- run_with_control(attempt, raw, specification, context),
           {:ok, _terminal} <- record_result(attempt, result, context),
           :ok <- enqueue_next() do
        {:ok, result.status}
      else
        {:error, reason} ->
          _ = record(attempt, 3, :failed, :system_failure, context)
          {:error, reason}
      end

    Log.event(
      if(match?({:ok, _status}, execution_result), do: :info, else: :error),
      "runner.attempt.completed",
      execution_metadata(attempt, raw, context)
      |> Map.put(:outcome, execution_outcome(execution_result))
    )

    case execution_result do
      {:ok, _status} -> :ok
      {:error, reason} -> {:error, reason}
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

  defp log_execution_start(attempt, raw, context) do
    Log.event(
      :info,
      "runner.attempt.started",
      Map.put(execution_metadata(attempt, raw, context), :outcome, :started)
    )
  end

  defp execution_metadata(attempt, raw, context) do
    %{
      correlation_id: context.correlation_id,
      pipeline_id: raw["pipeline_id"],
      repository_id: raw["repository_id"],
      job_id: raw["job_id"],
      attempt_id: attempt.id,
      runner_id: "local"
    }
  end

  defp execution_outcome({:ok, status}), do: status
  defp execution_outcome({:error, _reason}), do: :system_failure
end
