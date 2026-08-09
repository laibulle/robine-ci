defmodule Robine.Pipelines.UseCases.ClaimNextJob do
  @moduledoc "Claims one ready job and creates its uniquely identified attempt atomically."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies
  alias Robine.Pipelines.Domain.{Attempt, Job, PipelineProjectionRequested}

  @spec call(map(), ExecutionContext.t()) :: {:ok, Attempt.t()} | {:error, term()}
  def call(input, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{pipelines: %Dependencies{job_repository: repository} = deps}
      })
      when is_atom(repository) do
    global_limit = positive(input, :global_limit, 4)
    repository_limit = positive(input, :repository_limit, 2)
    lease_seconds = positive(input, :lease_seconds, 60)

    with :ok <- admit(deps) do
      deps.unit_of_work.transaction(fn ->
        with {:ok, job} <- repository.next_queued(global_limit, repository_limit),
             {:ok, pipeline} <- deps.pipeline_repository.get(job.pipeline_id),
             {:ok, running_pipeline} <- start_pipeline(pipeline, deps.clock.now()),
             {:ok, running_job} <- Job.transition(job, :running),
             {:ok, attempt} <- new_attempt(job, lease_seconds, deps, repository),
             :ok <- deps.pipeline_repository.update(running_pipeline),
             :ok <- repository.update_job(running_job),
             :ok <- repository.insert_attempt(attempt),
             :ok <- deps.event_outbox.append(projection_event(running_pipeline.id, deps)) do
          {:ok, attempt}
        end
      end)
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp new_attempt(job, lease_seconds, deps, repository) do
    Attempt.new(%{
      id: deps.id_generator.generate(),
      job_id: job.id,
      number: repository.next_attempt_number(job.id),
      idempotency_token: deps.id_generator.generate(),
      lease_expires_at: DateTime.add(deps.clock.now(), lease_seconds, :second)
    })
  end

  defp start_pipeline(%Robine.Pipelines.Domain.Pipeline{status: :running} = pipeline, _now),
    do: {:ok, pipeline}

  defp start_pipeline(pipeline, now),
    do: Robine.Pipelines.Domain.Pipeline.transition(pipeline, :running, now)

  defp positive(input, key, default) do
    case Map.get(input, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp admit(%Dependencies{admission: nil}), do: :ok
  defp admit(%Dependencies{admission: admission}), do: admission.check()

  defp projection_event(pipeline_id, deps) do
    %PipelineProjectionRequested{
      event_id: deps.id_generator.generate(),
      pipeline_id: pipeline_id,
      occurred_at: deps.clock.now(),
      dispatch: false
    }
  end
end
