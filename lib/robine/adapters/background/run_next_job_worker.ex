defmodule Robine.Adapters.Background.RunNextJobWorker do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 5]

  alias Robine.Execution
  alias Robine.Adapters.Runner.RemoteJobOffer
  alias Robine.Adapters.Background.RunnerControl
  alias Robine.Adapters.Background.TenantJob
  alias Robine.Observability.Log
  alias Robine.Pipelines
  alias Robine.Repositories
  alias Robine.Runners
  alias Robine.Runtime.Dependencies
  alias Robine.Runtime.Events
  alias Robine.Storage

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    runner_control = Application.fetch_env!(:robine, :runner_control)

    TenantJob.run(job, __MODULE__, "local-runner:#{Ecto.UUID.generate()}", fn context ->
      case dispatch_remote(context, runner_control) do
        :local -> claim_local(context, runner_control)
        result -> result
      end
    end)
  end

  defp claim_local(context, runner_control) do
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

      {:error, :none} ->
        :ok

      {:error, :capacity} ->
        {:snooze, 1}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch_remote(context, runner_control) do
    with {:ok, runner} <- Runners.select_available(%{}, context),
         {:ok, attempt} <-
           Pipelines.claim_next_job(
             %{
               runner_id: runner.id,
               lease_seconds: Keyword.fetch!(runner_control, :lease_seconds)
             },
             context
           ),
         runner_context =
           Dependencies.runner_context(context.tenant_id, runner.id, "attempt:#{attempt.id}"),
         {:ok, offer} <- RemoteJobOffer.build(attempt.id, runner_context),
         :ok <- Events.broadcast("runner:#{runner.id}", {:job_offer, offer}) do
      :ok
    else
      {:error, :none} -> :local
      {:error, :runner_unavailable} -> :local
      {:error, :capacity} -> {:snooze, 1}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute(attempt, context) do
    case record(attempt, 1, :preparing, nil, context) do
      {:ok, preparing_attempt} ->
        prepare_and_execute(preparing_attempt, context)

      {:error, reason} ->
        log_system_failure(attempt, reason, :attempt_preparation, context)
        {:error, reason}
    end
  end

  defp prepare_and_execute(attempt, context) do
    with {:ok, raw_specification} <-
           Pipelines.job_execution(%{idempotency_token: attempt.idempotency_token}, context),
         correlated_context = correlate(context, raw_specification),
         :ok <- log_execution_start(attempt, raw_specification, correlated_context),
         {:ok, source_path} <- materialize_source(raw_specification, correlated_context),
         {:ok, specification} <-
           Execution.build_ci_specification(
             %{persisted: raw_specification, source_path: source_path},
             correlated_context
           ) do
      try do
        execute_specification(attempt, raw_specification, specification, correlated_context)
      after
        cleanup_source(source_path)
      end
    else
      {:error, reason} -> fail_attempt(attempt, reason, :job_preparation, context)
    end
  end

  defp fail_attempt(attempt, reason, phase, context) do
    _ = persist_failure_diagnostic(attempt, reason, phase, context)

    result =
      record(
        attempt,
        attempt.last_sequence + 1,
        :failed,
        :system_failure,
        context
      )

    log_system_failure(attempt, reason, phase, context)

    case result do
      {:ok, _failed_attempt} -> {:error, reason}
      {:error, record_reason} -> {:error, {:failure_recording_failed, record_reason, reason}}
    end
  end

  defp log_system_failure(attempt, reason, phase, context) do
    Log.event(:error, "runner.attempt.completed", %{
      correlation_id: context.correlation_id,
      attempt_id: attempt.id,
      runner_id: "local",
      outcome: :system_failure,
      failure_class: failure_class(reason),
      phase: phase
    })
  end

  defp persist_failure_diagnostic(attempt, reason, phase, context) do
    Pipelines.append_log_event(
      %{
        attempt_id: attempt.id,
        sequence: 1,
        phase: :execution,
        stream: :system,
        step_position: 0,
        step_name: failure_step_name(phase),
        status: :failed,
        exit_code: nil,
        duration_ms: 0,
        content: failure_message(reason)
      },
      context
    )
  end

  defp failure_step_name(:job_preparation), do: "Job preparation"
  defp failure_step_name(_phase), do: "Runner preparation"

  defp failure_class({:secrets_missing, _names}), do: :secrets_missing
  defp failure_class({:secret_decryption_failed, _name, _reason}), do: :secret_decryption_failed
  defp failure_class({:source_materialization, _reason}), do: :source_materialization
  defp failure_class({:cache_checksum, _reason}), do: :cache_checksum
  defp failure_class({:invalid_specification, _field}), do: :invalid_specification
  defp failure_class({:invalid_specification, _field, _value}), do: :invalid_specification
  defp failure_class(_reason), do: :system_failure

  defp failure_message({:secrets_missing, names}) do
    "Required CI #{pluralize_secret(names)} unavailable: #{Enum.join(names, ", ")}. " <>
      "Add #{pronoun_for_secrets(names)} in repository secrets, then retry the job."
  end

  defp failure_message({:secret_decryption_failed, name, _reason}) do
    "Required CI secret #{name} could not be decrypted. Ask an administrator to replace it, then retry the job."
  end

  defp failure_message({:source_materialization, _reason}) do
    "Robine could not prepare the repository source for this job. Check source-control access and retry."
  end

  defp failure_message({:cache_checksum, :checkout_required}) do
    "A cache checksum requires a checkout step, but no source checkout is available. Update the workflow and retry."
  end

  defp failure_message({:invalid_specification, field}) do
    "Robine rejected the prepared job specification at #{field}. Update the workflow and retry."
  end

  defp failure_message({:invalid_specification, field, _value}) do
    "Robine rejected the prepared job specification at #{field}. Update the workflow and retry."
  end

  defp failure_message(_reason) do
    "Robine could not prepare this job for execution. Check instance health and retry."
  end

  defp pluralize_secret([_name]), do: "secret is"
  defp pluralize_secret(_names), do: "secrets are"

  defp pronoun_for_secrets([_name]), do: "it"
  defp pronoun_for_secrets(_names), do: "them"

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

    :telemetry.execute(
      [:robine, :runner, :exit],
      %{count: 1},
      %{reason: execution_outcome(execution_result)}
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

  defp persist_log_event(attempt_id, event, context) do
    result = Pipelines.append_log_event(Map.put(event, :attempt_id, attempt_id), context)

    if result == :ok do
      Events.broadcast("attempt-logs:#{attempt_id}", {:log_appended, attempt_id})

      :telemetry.execute(
        [:robine, :runner, :logs],
        %{bytes: byte_size(Map.get(event, :content, ""))},
        %{phase: Map.get(event, :phase, :execution)}
      )

      redaction_matches =
        event
        |> Map.get(:content, "")
        |> :binary.matches("[REDACTED]")
        |> length()

      if redaction_matches > 0 do
        :telemetry.execute(
          [:robine, :secrets, :redaction, :match],
          %{count: redaction_matches},
          %{}
        )
      end

      if Map.get(event, :status) in [:succeeded, :failed, :cancelled, :timed_out, :skipped] do
        :telemetry.execute(
          [:robine, :runner, :phase],
          %{duration: Map.get(event, :duration_ms, 0)},
          %{
            phase: Map.get(event, :phase, :execution),
            outcome: Map.get(event, :status)
          }
        )

        if Map.get(event, :phase) == :image_acquisition do
          :telemetry.execute(
            [:robine, :runner, :image_pull],
            %{duration: Map.get(event, :duration_ms, 0)},
            %{outcome: Map.get(event, :status)}
          )
        end
      end
    end

    result
  end

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
    case %{} |> TenantJob.put_tenant() |> new() |> Oban.insert() do
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

  defp correlate(context, %{"correlation_id" => correlation_id})
       when is_binary(correlation_id) and correlation_id != "",
       do: %{context | correlation_id: correlation_id}

  defp correlate(context, _raw), do: context
end
