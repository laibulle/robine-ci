defmodule Robine.Pipelines.UseCases.GetRemoteJobExecution do
  @moduledoc "Returns execution input only to the remote runner owning the claimed attempt."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies
  alias Robine.Pipelines.Domain.BuildProvenance

  def call(%{attempt_id: attempt_id}, %ExecutionContext{
        actor: %{id: runner_id, role: :runner},
        dependencies: %{pipelines: %Dependencies{job_repository: repository} = deps}
      })
      when is_binary(attempt_id) and is_atom(repository) do
    with {:ok, attempt} <- repository.get_attempt(attempt_id),
         true <- attempt.runner_id == runner_id,
         {:ok, job} <- repository.get_job(attempt.job_id),
         {:ok, pipeline} <- deps.pipeline_repository.get(job.pipeline_id),
         true <- map_size(job.execution) > 0 do
      {:ok,
       job.execution
       |> Map.put("build_env", BuildProvenance.environment(pipeline))
       |> Map.put("attempt_id", attempt.id)
       |> Map.put("job_id", job.id)
       |> Map.put("job_key", job.job_key)
       |> Map.put("needs", job.needs)
       |> Map.put("idempotency_token", attempt.idempotency_token)
       |> Map.put("pipeline_id", pipeline.id)
       |> Map.put("correlation_id", pipeline.correlation_id)
       |> Map.put("commit_sha", pipeline.commit_sha)
       |> Map.put("repository_id", pipeline.repository_id)}
    else
      false -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
