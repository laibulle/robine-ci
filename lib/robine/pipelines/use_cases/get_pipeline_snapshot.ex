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
      {:ok,
       %{
         id: pipeline.id,
         repository_id: pipeline.repository_id,
         workflow_name: pipeline.workflow_name,
         commit_sha: pipeline.commit_sha,
         status: pipeline.status,
         inserted_at: pipeline.inserted_at,
         jobs:
           Enum.map(
             jobs,
             &Map.take(Map.from_struct(&1), [:id, :job_key, :status, :position, :needs])
           )
       }}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
