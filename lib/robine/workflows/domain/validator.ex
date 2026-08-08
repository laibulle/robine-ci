defmodule Robine.Workflows.Domain.Validator do
  @moduledoc "Pure structural and semantic validation for workflow schema version 1."

  alias Robine.Workflows.Domain.{Diagnostic, Job, Step, Workflow}

  @root_keys ~w(version name on jobs)
  @job_keys ~w(image needs steps timeout env)
  @step_keys ~w(name run uses with)
  @builtins ~w(checkout cache/restore cache/save artifacts/upload artifacts/download)
  @job_id ~r/\A[a-z][a-z0-9_-]{0,62}\z/

  @spec validate(map()) :: {:ok, Workflow.t(), [Diagnostic.t()]} | {:error, [Diagnostic.t()]}
  def validate(document) when is_map(document) do
    errors = unknown_keys(document, @root_keys, [])

    with [] <- errors,
         {:ok, version} <- exact_version(document),
         {:ok, name} <- nonempty_string(document, "name", ["name"]),
         {:ok, triggers} <- triggers(document),
         {:ok, jobs, warnings} <- jobs(document),
         {:ok, order} <- topological_order(jobs) do
      {:ok, %Workflow{version: version, name: name, triggers: triggers, jobs: jobs, order: order},
       warnings}
    else
      errors when is_list(errors) -> {:error, errors}
      {:error, errors} when is_list(errors) -> {:error, errors}
      {:error, %Diagnostic{} = error} -> {:error, [error]}
    end
  end

  def validate(_document),
    do: {:error, [Diagnostic.error("workflow.type", "workflow must be a map", [])]}

  defp exact_version(%{"version" => 1}), do: {:ok, 1}

  defp exact_version(document) do
    {:error,
     Diagnostic.error(
       "workflow.version",
       "version must be 1, got #{inspect(Map.get(document, "version"))}",
       ["version"]
     )}
  end

  defp triggers(%{"on" => triggers}) when is_map(triggers) and map_size(triggers) > 0 do
    supported = ~w(push pull_request)
    errors = unknown_keys(triggers, supported, ["on"])
    if errors == [], do: {:ok, triggers}, else: {:error, errors}
  end

  defp triggers(_document) do
    {:error, Diagnostic.error("workflow.triggers", "on must contain a trigger", ["on"])}
  end

  defp jobs(%{"jobs" => jobs}) when is_map(jobs) and map_size(jobs) > 0 do
    {normalized, errors, warnings} =
      jobs
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({%{}, [], []}, fn {id, definition}, {acc, errors, warnings} ->
        case job(id, definition) do
          {:ok, normalized_job, job_warnings} ->
            {Map.put(acc, id, normalized_job), errors, warnings ++ job_warnings}

          {:error, job_errors} ->
            {acc, errors ++ job_errors, warnings}
        end
      end)

    reference_errors = dependency_reference_errors(normalized)
    all_errors = errors ++ reference_errors
    if all_errors == [], do: {:ok, normalized, warnings}, else: {:error, all_errors}
  end

  defp jobs(_document) do
    {:error, Diagnostic.error("workflow.jobs", "jobs must be a non-empty map", ["jobs"])}
  end

  defp job(id, definition) when is_binary(id) and is_map(definition) do
    errors =
      unknown_keys(definition, @job_keys, ["jobs", id]) ++
        if(Regex.match?(@job_id, id),
          do: [],
          else: [Diagnostic.error("job.id", "invalid job identifier", ["jobs", id])]
        )

    with [] <- errors,
         {:ok, image} <- nonempty_string(definition, "image", ["jobs", id, "image"]),
         {:ok, needs} <- needs(definition, id),
         {:ok, env} <- env(definition, id),
         {:ok, steps} <- steps(definition, id) do
      warnings = image_warnings(image, id)

      {:ok,
       %Job{
         id: id,
         image: image,
         needs: needs,
         env: env,
         timeout: Map.get(definition, "timeout"),
         steps: steps
       }, warnings}
    else
      {:error, %Diagnostic{} = error} -> {:error, [error]}
      {:error, errors} -> {:error, errors}
    end
  end

  defp job(id, _definition) do
    {:error, [Diagnostic.error("job.type", "job must be a map", ["jobs", to_string(id)])]}
  end

  defp needs(definition, id) do
    case Map.get(definition, "needs", []) do
      needs when is_list(needs) ->
        if Enum.all?(needs, &is_binary/1) do
          {:ok, Enum.uniq(needs)}
        else
          {:error,
           Diagnostic.error(
             "job.needs",
             "needs must contain only job IDs",
             ["jobs", id, "needs"]
           )}
        end

      need when is_binary(need) ->
        {:ok, [need]}

      _ ->
        {:error,
         Diagnostic.error("job.needs", "needs must be a job ID or list", ["jobs", id, "needs"])}
    end
  end

  defp env(definition, id) do
    case Map.get(definition, "env", %{}) do
      env when is_map(env) ->
        if Enum.all?(env, fn {key, value} -> is_binary(key) and is_binary(value) end) do
          {:ok, env}
        else
          {:error,
           Diagnostic.error("job.env", "environment keys and values must be strings", [
             "jobs",
             id,
             "env"
           ])}
        end

      _ ->
        {:error, Diagnostic.error("job.env", "env must be a map", ["jobs", id, "env"])}
    end
  end

  defp steps(%{"steps" => steps}, id) when is_list(steps) and steps != [] do
    {normalized, errors} =
      steps
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {definition, index}, {acc, errors} ->
        case step(definition, id, index) do
          {:ok, value} -> {[value | acc], errors}
          {:error, step_errors} -> {acc, errors ++ step_errors}
        end
      end)

    normalized = Enum.reverse(normalized)
    duplicate_errors = duplicate_step_names(normalized, id)
    all_errors = errors ++ duplicate_errors
    if all_errors == [], do: {:ok, normalized}, else: {:error, all_errors}
  end

  defp steps(_definition, id) do
    {:error,
     Diagnostic.error("job.steps", "steps must be a non-empty list", ["jobs", id, "steps"])}
  end

  defp step(definition, job_id, index) when is_map(definition) do
    path = ["jobs", job_id, "steps", index]
    errors = unknown_keys(definition, @step_keys, path)
    run = Map.get(definition, "run")
    builtin = Map.get(definition, "uses")

    kind_result =
      case {run, builtin} do
        {command, nil} when is_binary(command) and byte_size(command) > 0 ->
          {:ok, :run, command}

        {nil, name} when name in @builtins ->
          {:ok, :builtin, name}

        {nil, name} when is_binary(name) ->
          {:error,
           Diagnostic.error(
             "step.builtin",
             "unsupported built-in #{inspect(name)}",
             path ++ ["uses"]
           )}

        _ ->
          {:error,
           Diagnostic.error("step.action", "step must contain exactly one of run or uses", path)}
      end

    with [] <- errors,
         {:ok, kind, value} <- kind_result do
      name = Map.get(definition, "name") || default_step_name(kind, value, index)

      if is_binary(name) and byte_size(name) > 0 do
        {:ok, %Step{name: name, kind: kind, value: value, with: Map.get(definition, "with", %{})}}
      else
        {:error, [Diagnostic.error("step.name", "step name must be a string", path ++ ["name"])]}
      end
    else
      errors when is_list(errors) -> {:error, errors}
      {:error, %Diagnostic{} = error} -> {:error, [error]}
    end
  end

  defp step(_definition, job_id, index) do
    {:error,
     [Diagnostic.error("step.type", "step must be a map", ["jobs", job_id, "steps", index])]}
  end

  defp default_step_name(:builtin, value, _index), do: value
  defp default_step_name(:run, _value, index), do: "Run #{index + 1}"

  defp duplicate_step_names(steps, job_id) do
    steps
    |> Enum.group_by(& &1.name)
    |> Enum.filter(fn {_name, values} -> length(values) > 1 end)
    |> Enum.map(fn {name, _values} ->
      Diagnostic.error("step.name_duplicate", "duplicate step name #{inspect(name)}", [
        "jobs",
        job_id,
        "steps"
      ])
    end)
  end

  defp dependency_reference_errors(jobs) do
    Enum.flat_map(jobs, fn {id, job} ->
      Enum.flat_map(job.needs, fn dependency ->
        if Map.has_key?(jobs, dependency) do
          []
        else
          [
            Diagnostic.error("job.need_unknown", "unknown dependency #{inspect(dependency)}", [
              "jobs",
              id,
              "needs"
            ])
          ]
        end
      end)
    end)
  end

  defp topological_order(jobs) do
    indegrees = Map.new(jobs, fn {id, job} -> {id, length(job.needs)} end)

    ready =
      indegrees
      |> Enum.filter(fn {_id, count} -> count == 0 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    {order, remaining} = consume_graph(ready, jobs, indegrees, [])

    if map_size(remaining) == 0 do
      {:ok, order}
    else
      cycle_ids = remaining |> Map.keys() |> Enum.sort()

      {:error,
       Enum.map(cycle_ids, fn id ->
         Diagnostic.error("workflow.cycle", "job participates in a dependency cycle", [
           "jobs",
           id,
           "needs"
         ])
       end)}
    end
  end

  defp consume_graph([], _jobs, indegrees, order), do: {Enum.reverse(order), indegrees}

  defp consume_graph([id | ready], jobs, indegrees, order) do
    remaining = Map.delete(indegrees, id)

    {remaining, newly_ready} =
      jobs
      |> Enum.filter(fn {_candidate_id, job} -> id in job.needs end)
      |> Enum.reduce({remaining, []}, fn {candidate_id, _job}, {counts, released} ->
        case Map.fetch(counts, candidate_id) do
          {:ok, count} when count - 1 == 0 ->
            {Map.put(counts, candidate_id, 0), [candidate_id | released]}

          {:ok, count} ->
            {Map.put(counts, candidate_id, count - 1), released}

          :error ->
            {counts, released}
        end
      end)

    consume_graph(Enum.sort(ready ++ newly_ready), jobs, remaining, [id | order])
  end

  defp image_warnings(image, id) do
    if String.contains?(image, "@sha256:") do
      []
    else
      [
        Diagnostic.warning("job.image_mutable", "image is not pinned by digest", [
          "jobs",
          id,
          "image"
        ])
      ]
    end
  end

  defp nonempty_string(map, key, path) do
    case Map.get(map, key) do
      value when is_binary(value) and byte_size(value) > 0 ->
        {:ok, value}

      _ ->
        {:error, Diagnostic.error("workflow.required", "#{key} must be a non-empty string", path)}
    end
  end

  defp unknown_keys(map, allowed, path) do
    map
    |> Map.keys()
    |> Enum.reject(fn key ->
      is_binary(key) and (key in allowed or String.starts_with?(key, "x-"))
    end)
    |> Enum.sort()
    |> Enum.map(fn key ->
      Diagnostic.error(
        "workflow.unknown_key",
        "unknown key #{inspect(key)}",
        path ++ [to_string(key)]
      )
    end)
  end
end
