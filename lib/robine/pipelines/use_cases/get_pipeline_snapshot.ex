defmodule Robine.Pipelines.UseCases.GetPipelineSnapshot do
  @moduledoc "Returns a framework-free pipeline and job read projection."
  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies

  @spec call(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  def call(%{pipeline_id: pipeline_id}, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{pipelines: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer, :viewer] and is_binary(pipeline_id) do
    with {:ok, pipeline} <- deps.pipeline_repository.get(pipeline_id),
         {:ok, jobs} <- deps.job_repository.list_jobs(pipeline_id) do
      now = deps.clock.now()

      {:ok,
       %{
         id: pipeline.id,
         repository_id: pipeline.repository_id,
         workflow_name: pipeline.workflow_name,
         commit_sha: pipeline.commit_sha,
         trigger: pipeline.trigger,
         actor: pipeline.actor,
         correlation_id: pipeline.correlation_id,
         status: pipeline.status,
         inserted_at: pipeline.inserted_at,
         started_at: pipeline.started_at,
         finished_at: pipeline.finished_at,
         scheduled_for: pipeline.scheduled_for,
         inputs: pipeline.inputs,
         duration_ms: duration_ms(pipeline.started_at, pipeline.finished_at || now),
         jobs: Enum.map(jobs, &job_projection(&1, deps, now))
       }}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp job_projection(job, deps, now) do
    repository = deps.job_repository

    attempt =
      case repository.latest_attempt(job.id) do
        {:ok, value} -> value
        {:error, :not_found} -> nil
      end

    job
    |> Map.from_struct()
    |> Map.take([:id, :job_key, :status, :position, :needs])
    |> Map.merge(%{
      base_id: Map.get(job.execution, "base_id") || job.job_key,
      matrix_values: Map.get(job.execution, "matrix_values", %{}),
      phase: attempt && attempt.status,
      result_reason: attempt && attempt.result_reason,
      failure_detail: failure_detail(attempt, deps.log_repository),
      infrastructure_failure: attempt && attempt.result_reason in [:runner_lost, :system_failure],
      duration_ms: attempt && duration_ms(attempt.inserted_at, terminal_time(attempt, now))
    })
  end

  defp failure_detail(nil, _repository), do: nil

  defp failure_detail(attempt, log_repository) do
    case log_repository.latest(attempt.id, 1) do
      {:ok,
       [
         %{
           stream: "system",
           step_position: 0,
           step_name: step_name,
           step_status: "failed",
           content: content
         }
       ]}
      when step_name in ["Job preparation", "Runner preparation"] and is_binary(content) ->
        String.slice(content, 0, 1_000)

      _unavailable_or_regular_output ->
        nil
    end
  end

  defp terminal_time(%{status: status, updated_at: updated_at}, _now)
       when status in [:succeeded, :failed, :cancelled] and not is_nil(updated_at),
       do: updated_at

  defp terminal_time(_attempt, now), do: now

  defp duration_ms(%DateTime{} = started_at, %DateTime{} = finished_at),
    do: max(DateTime.diff(finished_at, started_at, :millisecond), 0)

  defp duration_ms(_started_at, _finished_at), do: nil
end
