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
           {:ok, updated_attempt} <-
             Attempt.record_event(attempt, sequence, status, Map.get(input, :reason)),
           :ok <- repository.update_attempt(updated_attempt),
           :ok <- reconcile_job(updated_attempt, repository),
           {:ok, pipeline_id} <- reconcile_graph(updated_attempt.job_id, deps),
           :ok <- maybe_project(attempt, updated_attempt, pipeline_id, deps) do
        {:ok, updated_attempt}
      end
    end)
  end

  def call(_input, %ExecutionContext{}), do: {:error, {:invalid_runner_event, :shape}}

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
         {:ok, completed_pipeline} <- Pipeline.complete_from_jobs(pipeline, refreshed_jobs),
         :ok <- persist_if_changed(pipeline, completed_pipeline, deps.pipeline_repository) do
      {:ok, source_job.pipeline_id}
    end
  end

  defp release_jobs(jobs, repository) do
    statuses = Map.new(jobs, &{&1.job_key, &1.status})

    Enum.reduce_while(jobs, :ok, fn job, :ok ->
      with {:ok, released} <- Job.release(job, statuses),
           :ok <- persist_if_changed(job, released, repository) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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
