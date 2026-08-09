defmodule Robine.Pipelines.UseCases.CreatePipeline do
  @moduledoc "Creates a pipeline and its outbox event atomically."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Contracts.PipelineView
  alias Robine.Pipelines.Dependencies
  alias Robine.Pipelines.Domain.{Pipeline, PipelineCreated, WorkflowRevision}

  @spec call(map(), ExecutionContext.t()) :: {:ok, PipelineView.t()} | {:error, term()}
  def call(
        input,
        %ExecutionContext{
          actor: actor,
          dependencies: %{pipelines: %Dependencies{} = deps}
        } = context
      )
      when actor.role in [:administrator, :maintainer] do
    deps.unit_of_work.transaction(fn ->
      now = deps.clock.now()
      jobs = Map.get(input, :jobs, %{})

      input = Map.put_new(input, :actor, actor.id)
      input = Map.put_new(input, :correlation_id, context.correlation_id)

      with {:ok, pipeline_id} <- pipeline_id(input, deps),
           :ok <- deps.unit_of_work.lock("pipeline:" <> pipeline_id) do
        case deps.pipeline_repository.get(pipeline_id) do
          {:ok, existing} -> reuse(existing, input, deps)
          {:error, :not_found} -> create(input, jobs, pipeline_id, now, deps)
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp create(input, jobs, pipeline_id, now, deps) do
    with {:ok, pipeline} <- Pipeline.create(input, pipeline_id, now),
         {:ok, revision} <- workflow_revision(input, jobs, pipeline_id, now, deps),
         :ok <- deps.pipeline_repository.insert(pipeline),
         :ok <- deps.pipeline_repository.insert_revision(revision),
         :ok <- insert_jobs(jobs, pipeline, deps),
         :ok <- deps.event_outbox.append(created_event(pipeline, deps)) do
      {:ok, PipelineView.from_domain(pipeline)}
    end
  end

  defp reuse(existing, input, deps) do
    expected = {
      Map.get(input, :repository_id),
      Map.get(input, :workflow_name),
      Map.get(input, :commit_sha),
      input |> Map.get(:trigger, :manual) |> to_string(),
      Map.get(input, :inputs, %{}),
      Map.get(input, :scheduled_for)
    }

    actual = {
      existing.repository_id,
      existing.workflow_name,
      existing.commit_sha,
      to_string(existing.trigger),
      existing.inputs,
      existing.scheduled_for
    }

    if actual == expected and same_revision?(existing.id, input, deps),
      do: {:ok, PipelineView.from_domain(existing)},
      else: {:error, :idempotency_conflict}
  end

  defp same_revision?(pipeline_id, %{workflow_revision: revision}, deps) do
    with {:ok, existing} <- deps.pipeline_repository.get_revision(pipeline_id) do
      existing.path == Map.get(revision, :path, Map.get(revision, "path")) and
        existing.source == Map.get(revision, :source, Map.get(revision, "source")) and
        same_included_sources?(existing.included_sources, Map.get(revision, :sources, %{}))
    else
      _error -> false
    end
  end

  defp same_revision?(_pipeline_id, _input, _deps), do: true

  defp same_included_sources?(stored, sources) do
    stored_sources = Map.new(stored, fn {path, value} -> {path, value["source"]} end)
    stored_sources == sources
  end

  defp pipeline_id(%{idempotency_key: key}, _deps)
       when is_binary(key),
       do: Pipeline.idempotent_id(key)

  defp pipeline_id(%{idempotency_key: _invalid}, _deps), do: {:error, :invalid_idempotency_key}
  defp pipeline_id(_input, deps), do: {:ok, deps.id_generator.generate()}

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
        execution:
          definition
          |> normalize_execution()
          |> Map.put_new("base_id", key)
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
      "timeout_ms" => normalized_timeout_ms(definition),
      "shell" => Map.get(definition, :shell, Map.get(definition, "shell", "/bin/sh")),
      "condition" =>
        definition
        |> Map.get(:condition, Map.get(definition, "condition", :success))
        |> to_string(),
      "base_id" => Map.get(definition, :base_id, Map.get(definition, "base_id")),
      "matrix_values" =>
        Map.get(definition, :matrix_values, Map.get(definition, "matrix_values", %{})),
      "secret_names" => Map.get(definition, :secrets, Map.get(definition, "secrets", [])),
      "services" =>
        definition
        |> Map.get(:services, Map.get(definition, "services", %{}))
        |> Map.new(fn {id, service} -> {to_string(id), normalize_service(service)} end),
      "runs_on" => Map.get(definition, :runs_on, Map.get(definition, "runs_on", ["docker"])),
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
      "condition" =>
        step |> Map.get(:condition, Map.get(step, "condition", :success)) |> to_string(),
      "with" => Map.get(step, :with, Map.get(step, "with", %{}))
    }
  end

  defp normalize_service(service) when is_struct(service),
    do: service |> Map.from_struct() |> normalize_service()

  defp normalize_service(service) when is_map(service) do
    readiness = Map.get(service, :readiness, Map.get(service, "readiness"))

    %{
      "id" => Map.get(service, :id, Map.get(service, "id")),
      "image" => Map.get(service, :image, Map.get(service, "image")),
      "privileged" => Map.get(service, :privileged, Map.get(service, "privileged", false)),
      "user" => Map.get(service, :user, Map.get(service, "user")),
      "env" => Map.get(service, :env, Map.get(service, "env", %{})),
      "secret_env" => Map.get(service, :secret_env, Map.get(service, "secret_env", %{})),
      "command" => Map.get(service, :command, Map.get(service, "command", [])),
      "readiness" => normalize_readiness(readiness)
    }
  end

  defp normalize_readiness(nil), do: nil

  defp normalize_readiness(readiness) do
    %{
      "tcp" => Map.get(readiness, :tcp, Map.get(readiness, "tcp")),
      "timeout_ms" => Map.get(readiness, :timeout_ms, Map.get(readiness, "timeout_ms"))
    }
  end

  defp normalized_timeout_ms(definition) do
    case Map.get(definition, :timeout_ms, Map.get(definition, "timeout_ms")) do
      value when is_integer(value) and value > 0 -> value
      _missing -> duration_ms(Map.get(definition, :timeout, Map.get(definition, "timeout")))
    end
  end

  defp duration_ms(value) when is_binary(value) do
    case Regex.run(~r/\A(\d+)(s|m|h)\z/, value) do
      [_, amount, "s"] -> String.to_integer(amount) * 1_000
      [_, amount, "m"] -> String.to_integer(amount) * 60_000
      [_, amount, "h"] -> String.to_integer(amount) * 3_600_000
      _invalid -> 1_200_000
    end
  end

  defp duration_ms(_value), do: 1_200_000

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
      sources: Map.get(revision, :sources, Map.get(revision, "sources", %{})),
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
