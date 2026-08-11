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

    with {:ok, pipelines} <- list_recent(deps.pipeline_repository, input, limit),
         {:ok, views} <- build_views(pipelines, deps.job_repository) do
      {:ok, views}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp list_recent(repository, %{repository_id: repository_id}, limit)
       when is_binary(repository_id) and repository_id != "" do
    if function_exported?(repository, :list_recent_for_repository, 2) do
      repository.list_recent_for_repository(repository_id, limit)
    else
      with {:ok, pipelines} <- repository.list_recent(limit) do
        {:ok, Enum.filter(pipelines, &(&1.repository_id == repository_id))}
      end
    end
  end

  defp list_recent(repository, _input, limit), do: repository.list_recent(limit)

  defp build_views(pipelines, job_repository) do
    Enum.reduce_while(pipelines, {:ok, []}, fn pipeline, {:ok, views} ->
      with {:ok, failure_job} <- failure_job(pipeline, job_repository) do
        view =
          pipeline
          |> Map.from_struct()
          |> Map.take([
            :id,
            :repository_id,
            :workflow_name,
            :commit_sha,
            :source_ref,
            :trigger,
            :actor,
            :correlation_id,
            :status,
            :inserted_at,
            :started_at,
            :finished_at,
            :scheduled_for,
            :inputs
          ])
          |> Map.put(:failure_job, failure_job)

        {:cont, {:ok, [view | views]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, views} -> {:ok, Enum.reverse(views)}
      error -> error
    end
  end

  defp failure_job(%{status: :failed, id: pipeline_id}, job_repository)
       when is_atom(job_repository) do
    with {:ok, jobs} <- job_repository.list_jobs(pipeline_id) do
      {:ok,
       jobs
       |> Enum.find(&(&1.status == :failed))
       |> then(&(&1 && %{id: &1.id, job_key: &1.job_key}))}
    end
  end

  defp failure_job(_pipeline, _job_repository), do: {:ok, nil}
end
