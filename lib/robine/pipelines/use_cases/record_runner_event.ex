defmodule Robine.Pipelines.UseCases.RecordRunnerEvent do
  @moduledoc "Records one ordered runner event and reconciles dependent durable state."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies
  alias Robine.Pipelines.Domain.{Attempt, Job, Pipeline, PipelineProjectionRequested}

  @terminal_attempts [:succeeded, :failed, :cancelled]
  @attempt_statuses [:queued, :preparing, :running, :cancelling, :succeeded, :failed, :cancelled]

  @spec call(map(), ExecutionContext.t()) :: {:ok, Attempt.t()} | {:error, term()}
  def call(
        %{idempotency_token: token, sequence: sequence, status: status} = input,
        %ExecutionContext{
          actor: %{role: :administrator},
          dependencies: %{pipelines: %Dependencies{job_repository: repository} = deps}
        }
      )
      when is_binary(token) and is_integer(sequence) and status in @attempt_statuses and
             is_atom(repository) do
    deps.unit_of_work.transaction(fn ->
      with {:ok, attempt} <- repository.get_attempt_by_token(token),
           {:ok, updated_attempt} <- apply_event(attempt, input, deps) do
        {:ok, updated_attempt}
      end
    end)
  end

  def call(
        %{
          idempotency_token: token,
          message_id: message_id,
          sequence: sequence,
          status: status
        } = input,
        %ExecutionContext{
          actor: %{id: runner_id, role: :runner},
          dependencies: %{pipelines: %Dependencies{job_repository: repository} = deps}
        }
      )
      when is_binary(token) and is_binary(message_id) and byte_size(message_id) in 1..128 and
             is_integer(sequence) and sequence > 0 and status in @attempt_statuses and
             is_atom(repository) do
    deps.unit_of_work.transaction(fn ->
      with {:ok, attempt} <- repository.get_attempt_by_token_for_update(token),
           :ok <- authorize_runner(attempt, runner_id),
           {:ok, outcome} <- remote_event_outcome(attempt, input, runner_id, deps) do
        {:ok, outcome}
      end
    end)
  end

  def call(_input, %ExecutionContext{}), do: {:error, {:invalid_runner_event, :shape}}

  defp remote_event_outcome(attempt, input, runner_id, deps) do
    case deps.job_repository.get_runner_event(runner_id, input.message_id) do
      {:ok, receipt} ->
        if same_message?(receipt, attempt, input),
          do: {:ok, attempt},
          else: {:error, :message_id_conflict}

      {:error, :not_found} ->
        if input.sequence <= attempt.last_sequence do
          {:error, {:stale_event_sequence, attempt.last_sequence, input.sequence}}
        else
          with {:ok, updated} <- apply_event(attempt, input, deps),
               :ok <-
                 deps.job_repository.insert_runner_event(%{
                   id: deps.id_generator.generate(),
                   runner_id: runner_id,
                   message_id: input.message_id,
                   attempt_id: attempt.id,
                   sequence: input.sequence,
                   status: input.status,
                   reason: Map.get(input, :reason),
                   inserted_at: deps.clock.now()
                 }) do
            {:ok, updated}
          end
        end
    end
  end

  defp apply_event(attempt, input, deps) do
    repository = deps.job_repository

    with {:ok, updated_attempt} <-
           Attempt.record_event(
             attempt,
             input.sequence,
             input.status,
             Map.get(input, :reason)
           ) do
      if updated_attempt == attempt do
        {:ok, attempt}
      else
        with :ok <- repository.update_attempt(updated_attempt),
             :ok <- lock_job_graph(updated_attempt.job_id, repository),
             :ok <- reconcile_job(updated_attempt, repository),
             {:ok, pipeline_id} <- reconcile_graph(updated_attempt.job_id, deps),
             :ok <- maybe_project(attempt, updated_attempt, pipeline_id, deps),
             {:ok, persisted_attempt} <-
               repository.get_attempt_by_token(updated_attempt.idempotency_token) do
          {:ok, persisted_attempt}
        end
      end
    end
  end

  defp authorize_runner(%Attempt{runner_id: runner_id}, runner_id), do: :ok
  defp authorize_runner(%Attempt{}, _runner_id), do: {:error, :attempt_not_assigned_to_runner}

  defp same_message?(receipt, attempt, input) do
    receipt.attempt_id == attempt.id and receipt.sequence == input.sequence and
      receipt.status == input.status and receipt.reason == Map.get(input, :reason)
  end

  defp lock_job_graph(job_id, repository) do
    with {:ok, job} <- repository.get_job(job_id),
         {:ok, _locked_jobs} <- repository.list_jobs_for_update(job.pipeline_id) do
      :ok
    end
  end

  defp reconcile_job(%Attempt{status: status} = attempt, repository)
       when status in @terminal_attempts do
    with {:ok, job} <- repository.get_job(attempt.job_id),
         {:ok, terminal_job} <- Job.transition(job, job_status(status)),
         :ok <- repository.update_job(terminal_job) do
      :ok
    end
  end

  defp reconcile_job(%Attempt{}, _repository), do: :ok

  defp reconcile_graph(job_id, deps) do
    repository = deps.job_repository

    with {:ok, source_job} <- repository.get_job(job_id),
         {:ok, jobs} <- repository.list_jobs(source_job.pipeline_id),
         :ok <- release_jobs(jobs, repository),
         {:ok, refreshed_jobs} <- repository.list_jobs(source_job.pipeline_id),
         {:ok, pipeline} <- deps.pipeline_repository.get(source_job.pipeline_id),
         {:ok, completed_pipeline} <-
           Pipeline.complete_from_jobs(pipeline, refreshed_jobs, deps.clock.now()),
         :ok <- persist_if_changed(pipeline, completed_pipeline, deps.pipeline_repository) do
      {:ok, source_job.pipeline_id}
    end
  end

  defp release_jobs(jobs, repository) do
    with {:ok, released_jobs} <- release_until_stable(jobs) do
      jobs
      |> Enum.zip(released_jobs)
      |> Enum.reduce_while(:ok, fn {job, released}, :ok ->
        case persist_if_changed(job, released, repository) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp release_until_stable(jobs) do
    statuses = Map.new(jobs, &{&1.job_key, &1.status})

    Enum.reduce_while(jobs, {:ok, []}, fn job, {:ok, released} ->
      case Job.release(job, statuses) do
        {:ok, updated} -> {:cont, {:ok, [updated | released]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} ->
        released = Enum.reverse(reversed)

        if released == jobs do
          {:ok, released}
        else
          release_until_stable(released)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_if_changed(value, value, _repository), do: :ok
  defp persist_if_changed(%Pipeline{}, changed, repository), do: repository.update(changed)
  defp persist_if_changed(%Job{}, changed, repository), do: repository.update_job(changed)

  defp job_status(:succeeded), do: :succeeded
  defp job_status(:failed), do: :failed
  defp job_status(:cancelled), do: :cancelled

  defp maybe_project(attempt, attempt, _pipeline_id, _deps), do: :ok

  defp maybe_project(_previous, %Attempt{status: status}, pipeline_id, deps)
       when status in @terminal_attempts do
    deps.event_outbox.append(%PipelineProjectionRequested{
      event_id: deps.id_generator.generate(),
      pipeline_id: pipeline_id,
      occurred_at: deps.clock.now(),
      dispatch: true
    })
  end

  defp maybe_project(_previous, _updated, _pipeline_id, _deps), do: :ok
end
