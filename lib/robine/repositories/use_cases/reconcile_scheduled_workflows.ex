defmodule Robine.Repositories.UseCases.ReconcileScheduledWorkflows do
  @moduledoc "Durably reconciles bounded UTC schedule occurrences at exact Git revisions."

  alias Robine.ExecutionContext
  alias Robine.Pipelines
  alias Robine.Repositories.Dependencies
  alias Robine.Repositories.Domain.ScheduleOccurrence
  alias Robine.Workflows

  @max_minutes 1_440

  @spec call(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  def call(
        _input,
        %ExecutionContext{
          actor: %{role: :administrator},
          dependencies: %{repositories: %Dependencies{} = deps}
        } = context
      ) do
    started = System.monotonic_time()
    current = deps.clock.now() |> DateTime.truncate(:second) |> floor_minute()

    result =
      with {:ok, cursor} <- deps.repository.get_schedule_cursor(),
           {:ok, window} <- window(cursor, current),
           {:ok, repositories} <- deps.repository.list(),
           {:ok, counts} <- reconcile_repositories(repositories, window.slots, deps, context),
           :ok <- advance_cursor(deps.repository, cursor, current) do
        {:ok,
         Map.merge(counts, %{
           cursor: current,
           scanned_minutes: length(window.slots),
           truncated_minutes: window.truncated_minutes
         })}
      end

    if match?({:error, _reason}, result) do
      {:error, reason} = result
      _ = deps.repository.record_schedule_failure(failure_label(reason), current)
    end

    emit(result, started)
    result
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp window(nil, current),
    do: {:ok, %{slots: [current], truncated_minutes: 0}}

  defp window(%DateTime{} = cursor, current) do
    difference = DateTime.diff(current, cursor, :minute)

    cond do
      difference < 0 ->
        {:error, :schedule_cursor_ahead}

      difference == 0 ->
        {:ok, %{slots: [], truncated_minutes: 0}}

      true ->
        scanned = min(difference, @max_minutes)
        first = DateTime.add(current, -(scanned - 1), :minute)

        {:ok,
         %{
           slots: Enum.map(0..(scanned - 1), &DateTime.add(first, &1, :minute)),
           truncated_minutes: max(difference - @max_minutes, 0)
         }}
    end
  end

  defp reconcile_repositories(repositories, slots, deps, context) do
    repositories
    |> Enum.filter(& &1.trusted)
    |> Enum.reduce_while({:ok, %{due_occurrences: 0, pipelines: 0}}, fn repository,
                                                                        {:ok, counts} ->
      case reconcile_repository(repository, slots, deps, context) do
        {:ok, repository_counts} ->
          {:cont,
           {:ok,
            %{
              due_occurrences: counts.due_occurrences + repository_counts.due_occurrences,
              pipelines: counts.pipelines + repository_counts.pipelines
            }}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp reconcile_repository(_repository, [], _deps, _context),
    do: {:ok, %{due_occurrences: 0, pipelines: 0}}

  defp reconcile_repository(repository, slots, deps, context) do
    with {:ok, head} <- deps.source_control.default_branch_head(repository),
         {:ok, head} <- valid_head(head),
         {:ok, files} <- deps.source_control.workflow_files(repository, head.sha),
         {:ok, workflows} <- validate_files(files, context) do
      reconcile_workflows(repository, head, workflows, slots, deps, context)
    end
  end

  defp validate_files(files, context) do
    sources = Map.new(files, &{&1.path, &1.content})

    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, workflows} ->
      case Workflows.resolve(%{entry_path: file.path, sources: sources}, context) do
        {:ok, validated} -> {:cont, {:ok, workflows ++ [{file, validated}]}}
        {:error, diagnostics} -> {:halt, {:error, {:invalid_workflow, file.path, diagnostics}}}
      end
    end)
  end

  defp valid_head(%{branch: branch, sha: sha} = head)
       when is_binary(branch) and branch != "" and is_binary(sha) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
      do: {:ok, head},
      else: {:error, :invalid_default_branch_head}
  end

  defp valid_head(_head), do: {:error, :invalid_default_branch_head}

  defp reconcile_workflows(repository, head, workflows, slots, deps, context) do
    Enum.reduce_while(workflows, {:ok, %{due_occurrences: 0, pipelines: 0}}, fn
      {file, validated}, {:ok, counts} ->
        schedules = Map.get(validated.workflow.triggers, "schedule", [])

        case reconcile_schedules(
               repository,
               head,
               file,
               validated,
               schedules,
               slots,
               deps,
               context
             ) do
          {:ok, schedule_counts} ->
            {:cont,
             {:ok,
              %{
                due_occurrences: counts.due_occurrences + schedule_counts.due_occurrences,
                pipelines: counts.pipelines + schedule_counts.pipelines
              }}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
  end

  defp reconcile_schedules(repository, head, file, validated, schedules, slots, deps, context) do
    occurrences =
      for schedule <- schedules,
          slot <- slots,
          {:ok, true} <- [Workflows.evaluate_schedule(%{schedule: schedule, datetime: slot})],
          do: {schedule, slot}

    Enum.reduce_while(occurrences, {:ok, %{due_occurrences: 0, pipelines: 0}}, fn
      {schedule, slot}, {:ok, counts} ->
        case create_occurrence(repository, head, file, validated, schedule, slot, deps, context) do
          {:ok, _pipeline} ->
            {:cont,
             {:ok,
              %{
                due_occurrences: counts.due_occurrences + 1,
                pipelines: counts.pipelines + 1
              }}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
  end

  defp create_occurrence(repository, head, file, validated, schedule, slot, deps, context) do
    idempotency_key =
      ScheduleOccurrence.idempotency_key(repository.id, file.path, schedule.cron, slot)

    pipeline_result =
      case Pipelines.create_pipeline(
             %{
               repository_id: repository.id,
               workflow_name: validated.workflow.name,
               commit_sha: head.sha,
               source_ref: head.branch,
               trigger: :schedule,
               actor: context.actor.id,
               scheduled_for: slot,
               inputs: %{},
               idempotency_key: idempotency_key,
               jobs: validated.workflow.jobs,
               workflow_revision: revision(file, validated)
             },
             context
           ) do
        {:error, :idempotency_conflict} ->
          Pipelines.get_idempotent_pipeline(%{idempotency_key: idempotency_key}, context)

        result ->
          result
      end

    with {:ok, pipeline} <- pipeline_result,
         :ok <-
           audit(
             deps,
             context,
             repository.id,
             file.path,
             pipeline.commit_sha,
             schedule.cron,
             slot,
             pipeline.id
           ) do
      {:ok, pipeline}
    end
  end

  defp revision(file, validated) do
    %{
      path: file.path,
      source: file.content,
      sources: Map.delete(validated.sources, file.path)
    }
  end

  defp audit(deps, context, repository_id, path, sha, cron, slot, pipeline_id) do
    deps.repository.audit_scheduled_launch(%{
      actor_id: context.actor.id,
      correlation_id: context.correlation_id,
      repository_id: repository_id,
      workflow_path: path,
      commit_sha: sha,
      cron: cron,
      scheduled_for: slot,
      pipeline_id: pipeline_id,
      occurred_at: DateTime.truncate(deps.clock.now(), :microsecond)
    })
  end

  defp advance_cursor(repository, expected, current) do
    case repository.advance_schedule_cursor(expected, current) do
      :ok ->
        :ok

      {:error, :cursor_conflict} ->
        case repository.get_schedule_cursor() do
          {:ok, cursor} when not is_nil(cursor) ->
            if DateTime.compare(cursor, current) in [:eq, :gt],
              do: :ok,
              else: {:error, :cursor_conflict}

          _error ->
            {:error, :cursor_conflict}
        end

      error ->
        error
    end
  end

  defp floor_minute(datetime), do: %{datetime | second: 0, microsecond: {0, 6}}

  defp failure_label({:invalid_workflow, _path, _diagnostics}), do: "invalid_workflow"
  defp failure_label({tag, _details}) when is_atom(tag), do: to_string(tag)
  defp failure_label(reason) when is_atom(reason), do: to_string(reason)
  defp failure_label(_reason), do: "schedule_reconciliation_failed"

  defp emit(result, started) do
    counts =
      case result do
        {:ok, value} ->
          value

        {:error, _reason} ->
          %{scanned_minutes: 0, due_occurrences: 0, pipelines: 0, truncated_minutes: 0}
      end

    :telemetry.execute(
      [:robine, :workflow, :schedule],
      %{
        duration: System.monotonic_time() - started,
        scanned_minutes: counts.scanned_minutes,
        due_occurrences: counts.due_occurrences,
        pipelines: counts.pipelines,
        truncated_minutes: counts.truncated_minutes
      },
      %{outcome: if(match?({:ok, _}, result), do: :ok, else: :error)}
    )
  end
end
