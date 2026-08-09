defmodule Robine.Execution.UseCases.BuildLocalPlan do
  @moduledoc "Builds deterministic local execution specifications from a validated workflow."

  alias Robine.Execution.Contracts.{Service, Specification, Step}
  alias Robine.Execution.Domain.CacheKey
  alias Robine.ExecutionContext
  alias Robine.Workflows.Contracts.ValidatedWorkflow

  @default_timeout_ms 1_200_000

  @spec call(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  def call(
        %{
          validated_workflow: %ValidatedWorkflow{workflow: workflow},
          source_path: source_path
        } = input,
        %ExecutionContext{actor: %{role: role}}
      )
      when role in [:administrator, :maintainer] and is_binary(source_path) do
    with {:ok, selected_ids} <- select_jobs(workflow, input),
         {:ok, specifications} <- specifications(workflow, selected_ids, source_path, input) do
      {:ok,
       %{
         workflow_name: workflow.name,
         workflow_revision: revision(workflow),
         specifications: specifications,
         selected_jobs: selected_ids,
         dependencies_omitted: Map.get(input, :no_deps, false),
         local_secret_count:
           specifications
           |> Enum.flat_map(&Map.keys(&1.secrets))
           |> Enum.uniq()
           |> length(),
         ci_only_inputs_omitted: ["GitHub event payload", "server-side secrets", "remote caches"]
       }}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp select_jobs(workflow, %{job_id: nil}), do: {:ok, workflow.order}

  defp select_jobs(workflow, %{job_id: job_id} = input) do
    matched_ids =
      cond do
        Map.has_key?(workflow.jobs, job_id) -> [job_id]
        true -> workflow.order |> Enum.filter(&(workflow.jobs[&1].base_id == job_id))
      end

    if matched_ids != [] do
      selected =
        if Map.get(input, :no_deps, false),
          do: MapSet.new(matched_ids),
          else: Enum.reduce(matched_ids, MapSet.new(), &dependencies(workflow.jobs, &1, &2))

      {:ok, Enum.filter(workflow.order, &MapSet.member?(selected, &1))}
    else
      choices = workflow.order |> Enum.map(&workflow.jobs[&1].base_id) |> Enum.uniq()
      {:error, {:unknown_job, job_id, choices}}
    end
  end

  defp dependencies(jobs, job_id, found) do
    if MapSet.member?(found, job_id) do
      found
    else
      Enum.reduce(jobs[job_id].needs, MapSet.put(found, job_id), &dependencies(jobs, &1, &2))
    end
  end

  defp specifications(workflow, selected_ids, source_path, input) do
    Enum.reduce_while(selected_ids, {:ok, []}, fn job_id, {:ok, result} ->
      job = workflow.jobs[job_id]

      with {:ok, steps} <- select_steps(job.steps, Map.get(input, :step)),
           {:ok, local_secrets} <- local_secrets(job.secrets, input),
           {:ok, services} <- local_services(job.services, local_secrets),
           steps = omit_checkout(steps),
           true <- steps != [],
           {:ok, execution_steps} <- execution_steps(steps, source_path) do
        specification = %Specification{
          version: 1,
          attempt_id: "local-#{job_id}-#{System.unique_integer([:positive])}",
          image: job.image,
          workspace: "/workspace",
          shell: job.shell,
          steps: execution_steps,
          timeout_ms: timeout_ms(job.timeout),
          source_path: Path.expand(source_path),
          env: job.env,
          secrets: local_secrets,
          services: services,
          metadata: %{
            "job_id" => job_id,
            "local" => true,
            "needs" => job.needs,
            "condition" => job.condition,
            "base_id" => job.base_id,
            "matrix_values" => job.matrix_values
          }
        }

        {:cont, {:ok, result ++ [specification]}}
      else
        false -> {:halt, {:error, {:no_local_steps, job_id}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp select_steps(steps, nil), do: {:ok, steps}

  defp select_steps(steps, selector) do
    selected =
      case Integer.parse(to_string(selector)) do
        {index, ""} when index > 0 -> Enum.at(steps, index - 1)
        _value -> Enum.find(steps, &(&1.name == selector))
      end

    if selected, do: {:ok, [selected]}, else: {:error, {:unknown_step, selector}}
  end

  defp local_secrets(required, %{local_secret_file: true, local_secrets: available}) do
    missing = required -- Map.keys(available)

    if missing == [],
      do: {:ok, Map.take(available, required)},
      else: {:error, {:local_secrets_missing, missing}}
  end

  defp local_secrets(_required, _input), do: {:ok, %{}}

  defp local_services(services, secret_values) do
    services
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {_id, service}, {:ok, resolved} ->
      case resolve_local_service_secrets(service.secret_env, secret_values) do
        {:ok, secret_env} ->
          execution = %Service{
            id: service.id,
            image: service.image,
            user: service.user,
            env: service.env,
            secret_env: secret_env,
            command: service.command,
            readiness: service.readiness
          }

          {:cont, {:ok, [execution | resolved]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      error -> error
    end
  end

  defp resolve_local_service_secrets(names, values) do
    Enum.reduce_while(names, {:ok, %{}}, fn {environment_name, secret_name}, {:ok, resolved} ->
      case Map.fetch(values, secret_name) do
        {:ok, value} -> {:cont, {:ok, Map.put(resolved, environment_name, value)}}
        :error -> {:halt, {:error, {:local_service_secret_missing, secret_name}}}
      end
    end)
  end

  defp omit_checkout(steps),
    do: Enum.reject(steps, &(&1.kind == :builtin and &1.value == "checkout"))

  defp execution_steps(steps, source_path) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, result} ->
      execution = %Step{
        name: step.name,
        kind: step.kind,
        value: step.value,
        condition: step.condition,
        with: step.with
      }

      case resolve_cache_key(execution, source_path) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | result]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  defp resolve_cache_key(%Step{value: value, with: %{"key" => key}} = step, source_path)
       when value in ["cache/restore", "cache/save"] do
    case CacheKey.resolve(key, source_path) do
      {:ok, resolved} -> {:ok, %{step | with: Map.put(step.with, "key", resolved)}}
      error -> error
    end
  end

  defp resolve_cache_key(step, _source_path), do: {:ok, step}

  defp timeout_ms(nil), do: @default_timeout_ms

  defp timeout_ms(value) do
    case Regex.run(~r/\A(\d+)(s|m|h)\z/, value) do
      [_, amount, "s"] -> String.to_integer(amount) * 1_000
      [_, amount, "m"] -> String.to_integer(amount) * 60_000
      [_, amount, "h"] -> String.to_integer(amount) * 3_600_000
      _ -> @default_timeout_ms
    end
  end

  defp revision(workflow) do
    :crypto.hash(:sha256, :erlang.term_to_binary(workflow)) |> Base.encode16(case: :lower)
  end
end
