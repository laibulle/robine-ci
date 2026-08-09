defmodule Robine.Pipelines.UseCases.ListPipelines do
  @moduledoc "Lists a bounded recent pipeline projection."
  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies

  def call(input, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{pipelines: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer, :viewer] do
    limit = input |> Map.get(:limit, 50) |> min(100) |> max(1)

    with {:ok, pipelines} <- deps.pipeline_repository.list_recent(limit) do
      {:ok,
       Enum.map(pipelines, fn pipeline ->
         Map.take(Map.from_struct(pipeline), [
           :id,
           :repository_id,
           :workflow_name,
           :commit_sha,
           :trigger,
           :actor,
           :status,
           :inserted_at,
           :started_at,
           :finished_at
         ])
       end)}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
