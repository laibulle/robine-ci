defmodule Robine.Pipelines.UseCases.GetJobDetail do
  @moduledoc "Returns a framework-free job and latest-attempt projection."
  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies

  def call(%{job_id: job_id}, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{pipelines: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer, :viewer] and is_binary(job_id) do
    with {:ok, job} <- deps.job_repository.get_job(job_id),
         {:ok, pipeline} <- deps.pipeline_repository.get(job.pipeline_id) do
      attempt =
        case deps.job_repository.latest_attempt(job_id) do
          {:ok, value} -> value
          {:error, :not_found} -> nil
        end

      {:ok,
       %{
         pipeline:
           Map.take(Map.from_struct(pipeline), [:id, :workflow_name, :commit_sha, :status]),
         job: Map.take(Map.from_struct(job), [:id, :job_key, :status, :needs, :position]),
         attempt:
           attempt && Map.take(Map.from_struct(attempt), [:id, :number, :status, :result_reason])
       }}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
