defmodule Robine.Pipelines.UseCases.GetJobExecution do
  @moduledoc "Returns the persisted normalized execution input for one claimed attempt."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies

  @spec call(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  def call(%{idempotency_token: token}, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{
          pipelines: %Dependencies{job_repository: repository} = pipeline_dependencies
        }
      })
      when is_binary(token) and is_atom(repository) do
    with {:ok, attempt} <- repository.get_attempt_by_token(token),
         {:ok, job} <- repository.get_job(attempt.job_id),
         {:ok, pipeline} <- pipeline_dependencies.pipeline_repository.get(job.pipeline_id),
         true <- map_size(job.execution) > 0 do
      {:ok,
       job.execution
       |> Map.put("attempt_id", attempt.id)
       |> Map.put("idempotency_token", attempt.idempotency_token)
       |> Map.put("repository_id", pipeline.repository_id)}
    else
      false -> {:error, :execution_specification_missing}
      error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
