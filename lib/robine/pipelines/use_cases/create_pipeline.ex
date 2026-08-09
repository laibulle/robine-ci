defmodule Robine.Pipelines.UseCases.CreatePipeline do
  @moduledoc "Creates a pipeline and its outbox event atomically."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Contracts.PipelineView
  alias Robine.Pipelines.Dependencies
  alias Robine.Pipelines.Domain.{Pipeline, PipelineCreated, WorkflowRevision}

  @spec call(map(), ExecutionContext.t()) :: {:ok, PipelineView.t()} | {:error, term()}
  def call(input, %ExecutionContext{
        actor: actor,
        dependencies: %{pipelines: %Dependencies{} = deps}
      })
      when actor.role in [:administrator, :maintainer] do
    deps.unit_of_work.transaction(fn ->
      now = deps.clock.now()
      pipeline_id = deps.id_generator.generate()
      jobs = Map.get(input, :jobs, %{})

      with {:ok, pipeline} <- Pipeline.create(input, pipeline_id, now),
           {:ok, revision} <- workflow_revision(input, jobs, pipeline_id, now, deps),
           :ok <- deps.pipeline_repository.insert(pipeline),
           :ok <- deps.pipeline_repository.insert_revision(revision),
           :ok <- insert_jobs(jobs, pipeline, deps),
           :ok <- deps.event_outbox.append(created_event(pipeline, deps)) do
        {:ok, PipelineView.from_domain(pipeline)}
      end
    end)
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp created_event(pipeline, deps) do
    %PipelineCreated{
      event_id: deps.id_generator.generate(),
      pipeline_id: pipeline.id,
      repository_id: pipeline.repository_id,
      occurred_at: pipeline.inserted_at
    }
  end

  defp insert_jobs(jobs, _pipeline, _deps) when jobs == %{} or jobs == [], do: :ok

  defp insert_jobs(jobs, pipeline, %{job_repository: repository} = deps)
       when is_map(jobs) and is_atom(repository) do
    jobs
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{key, definition}, position}, {:ok, acc} ->
      input = %{
        id: deps.id_generator.generate(),
        pipeline_id: pipeline.id,
        job_key: key,
        needs: Map.get(definition, :needs, Map.get(definition, "needs", [])) |> List.wrap(),
        position: position,
        execution: normalize_execution(definition)
      }

      case Robine.Pipelines.Domain.Job.new(input) do
        {:ok, job} -> {:cont, {:ok, [job | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> repository.insert_all(Enum.reverse(normalized))
      error -> error
    end
  end

  defp insert_jobs(_jobs, _pipeline, _deps), do: {:error, :job_repository_unavailable}

  defp normalize_execution(definition) when is_struct(definition),
    do: definition |> Map.from_struct() |> normalize_execution()

  defp normalize_execution(definition) when is_map(definition) do
    %{
      "image" => Map.get(definition, :image, Map.get(definition, "image")),
      "env" => Map.get(definition, :env, Map.get(definition, "env", %{})),
      "timeout_ms" =>
        Map.get(definition, :timeout_ms, Map.get(definition, "timeout_ms", 1_200_000)),
      "shell" => Map.get(definition, :shell, Map.get(definition, "shell", "/bin/sh")),
      "secret_names" => Map.get(definition, :secrets, Map.get(definition, "secrets", [])),
      "steps" =>
        definition
        |> Map.get(:steps, Map.get(definition, "steps", []))
        |> Enum.map(&normalize_step/1)
    }
  end

  defp normalize_step(step) when is_struct(step),
    do: step |> Map.from_struct() |> normalize_step()

  defp normalize_step(step) when is_map(step) do
    %{
      "name" => Map.get(step, :name, Map.get(step, "name")),
      "kind" => Map.get(step, :kind, Map.get(step, "kind")),
      "value" => Map.get(step, :value, Map.get(step, "value")),
      "with" => Map.get(step, :with, Map.get(step, "with", %{}))
    }
  end

  defp workflow_revision(input, jobs, pipeline_id, now, deps) do
    graph = normalized_graph(jobs)

    revision =
      Map.get(input, :workflow_revision, %{
        path: "generated://pipeline/#{pipeline_id}",
        source: Jason.encode!(graph)
      })

    WorkflowRevision.new(%{
      id: deps.id_generator.generate(),
      pipeline_id: pipeline_id,
      path: Map.get(revision, :path, Map.get(revision, "path")),
      source: Map.get(revision, :source, Map.get(revision, "source")),
      normalized_graph: graph,
      created_at: now
    })
  end

  defp normalized_graph(jobs) when is_map(jobs) do
    %{
      "jobs" =>
        jobs
        |> Enum.sort_by(&elem(&1, 0))
        |> Map.new(fn {key, definition} ->
          {to_string(key),
           definition
           |> normalize_execution()
           |> Map.put("needs", Map.get(definition, :needs, Map.get(definition, "needs", [])))}
        end)
    }
  end

  defp normalized_graph(_jobs), do: %{"jobs" => %{}}
end
