defmodule Robine.Pipelines.UseCases.CancelPipeline do
  @moduledoc "Requests cancellation without losing terminal pipeline history."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Contracts.PipelineView
  alias Robine.Pipelines.Dependencies
  alias Robine.Pipelines.Domain.{Job, Pipeline, PipelineProjectionRequested}

  @spec call(map(), ExecutionContext.t()) :: {:ok, PipelineView.t()} | {:error, term()}
  def call(%{pipeline_id: id}, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{pipelines: %Dependencies{} = deps}
      })
      when is_binary(id) and role in [:administrator, :maintainer] do
    deps.unit_of_work.transaction(fn ->
      with {:ok, pipeline} <- deps.pipeline_repository.get(id),
           {:ok, cancelled} <- Pipeline.request_cancellation(pipeline),
           :ok <- cancel_jobs(id, deps),
           :ok <- deps.pipeline_repository.update(cancelled),
           :ok <- deps.event_outbox.append(projection_event(cancelled.id, deps)) do
        {:ok, PipelineView.from_domain(cancelled)}
      end
    end)
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp cancel_jobs(_pipeline_id, %{job_repository: nil}), do: :ok

  defp cancel_jobs(pipeline_id, deps) do
    with {:ok, jobs} <- deps.job_repository.list_jobs(pipeline_id) do
      Enum.reduce_while(jobs, :ok, fn job, :ok ->
        case cancellation_target(job) do
          nil ->
            {:cont, :ok}

          target ->
            with {:ok, changed} <- Job.transition(job, target),
                 :ok <- deps.job_repository.update_job(changed) do
              {:cont, :ok}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end
        end
      end)
    end
  end

  defp cancellation_target(%Job{status: status}) when status in [:blocked, :queued],
    do: :cancelled

  defp cancellation_target(%Job{status: :running}), do: :cancelling
  defp cancellation_target(%Job{}), do: nil

  defp projection_event(pipeline_id, deps) do
    %PipelineProjectionRequested{
      event_id: deps.id_generator.generate(),
      pipeline_id: pipeline_id,
      occurred_at: deps.clock.now(),
      dispatch: false
    }
  end
end
