defmodule Robine.Pipelines.UseCases.RetryJob do
  @moduledoc "Requeues one failed or cancelled job after validating its durable prerequisites."
  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies
  alias Robine.Pipelines.Domain.{Job, Pipeline, PipelineProjectionRequested}

  def call(%{job_id: job_id} = input, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{pipelines: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer] and is_binary(job_id) do
    deps.unit_of_work.transaction(fn ->
      with {:ok, job} <- deps.job_repository.get_job(job_id),
           {:ok, jobs} <- deps.job_repository.list_jobs(job.pipeline_id),
           :ok <- dependencies_available(job, jobs),
           {:ok, pipeline} <- deps.pipeline_repository.get(job.pipeline_id),
           {:ok, reopened_pipeline} <- Pipeline.reopen_for_retry(pipeline, deps.clock.now()),
           {:ok, result} <- retry_strategy(job, jobs, input, deps),
           :ok <- deps.pipeline_repository.update(reopened_pipeline),
           :ok <- deps.event_outbox.append(projection_event(reopened_pipeline.id, deps)) do
        {:ok, Map.merge(result, %{pipeline_id: reopened_pipeline.id})}
      end
    end)
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp dependencies_available(job, jobs) do
    statuses = Map.new(jobs, &{&1.job_key, &1.status})
    missing = Enum.reject(job.needs, &(statuses[&1] == :succeeded))
    if missing == [], do: :ok, else: {:error, {:retry_dependencies_unavailable, missing}}
  end

  defp retry_strategy(job, jobs, input, deps) do
    with {:ok, missing} <- missing_artifact_inputs(job, deps) do
      cond do
        missing == [] -> retry_single(job, deps)
        Map.get(input, :rerun_dependencies, false) -> rerun_dependencies(job, jobs, missing, deps)
        true -> unavailable(missing)
      end
    end
  end

  defp retry_single(job, deps) do
    with {:ok, retried} <- Job.retry(job),
         :ok <- deps.job_repository.update_job(retried) do
      {:ok, %{job_id: retried.id, status: retried.status, rerun_jobs: []}}
    end
  end

  defp missing_artifact_inputs(job, deps) do
    requirements =
      job.execution
      |> Map.get("steps", [])
      |> Enum.flat_map(fn step ->
        if step["kind"] in [:builtin, "builtin"] and step["value"] == "artifacts/download" do
          [%{from: step["with"]["from"], name: step["with"]["name"]}]
        else
          []
        end
      end)
      |> Enum.uniq()

    cond do
      requirements == [] ->
        {:ok, []}

      not function_exported?(deps.job_repository, :missing_artifact_inputs, 3) ->
        {:ok, requirements}

      true ->
        case deps.job_repository.missing_artifact_inputs(
               job.pipeline_id,
               requirements,
               deps.clock.now()
             ) do
          {:ok, missing} -> {:ok, missing}
          error -> error
        end
    end
  end

  defp rerun_dependencies(target, jobs, missing, deps) do
    jobs_by_key = Map.new(jobs, &{&1.job_key, &1})
    producer_keys = missing |> Enum.map(& &1.from) |> MapSet.new()

    with :ok <- validate_producers(producer_keys, target, jobs_by_key),
         {:ok, target_reset} <- Job.reset_for_rerun(target, :blocked),
         {:ok, producers} <- reset_producers(producer_keys, jobs_by_key),
         :ok <- persist_jobs([target_reset | producers], deps.job_repository) do
      {:ok,
       %{
         job_id: target_reset.id,
         status: target_reset.status,
         rerun_jobs: producers |> Enum.sort_by(& &1.position) |> Enum.map(& &1.job_key)
       }}
    end
  end

  defp validate_producers(keys, target, jobs_by_key) do
    cond do
      not Enum.all?(keys, &Map.has_key?(jobs_by_key, &1)) ->
        {:error, :artifact_producer_not_found}

      not Enum.all?(keys, &(&1 in target.needs)) ->
        {:error, :artifact_producer_is_not_a_declared_dependency}

      true ->
        :ok
    end
  end

  defp reset_producers(keys, jobs_by_key) do
    keys
    |> Enum.sort_by(&jobs_by_key[&1].position)
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, result} ->
      job = jobs_by_key[key]
      target = if Enum.any?(job.needs, &MapSet.member?(keys, &1)), do: :blocked, else: :queued

      case Job.reset_for_rerun(job, target) do
        {:ok, reset} -> {:cont, {:ok, [reset | result]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  defp persist_jobs(jobs, repository) do
    Enum.reduce_while(jobs, :ok, fn job, :ok ->
      case repository.update_job(job) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp unavailable(requirements) do
    {:error,
     {:retry_inputs_unavailable,
      %{
        inputs: Enum.map(requirements, &"#{&1.from}/#{&1.name}"),
        rerun_jobs: requirements |> Enum.map(& &1.from) |> Enum.uniq()
      }}}
  end

  defp projection_event(pipeline_id, deps) do
    %PipelineProjectionRequested{
      event_id: deps.id_generator.generate(),
      pipeline_id: pipeline_id,
      occurred_at: deps.clock.now(),
      dispatch: true
    }
  end
end
