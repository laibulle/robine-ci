defmodule Robine.Execution.UseCases.BuildLocalPlan do
  @moduledoc "Builds deterministic local execution specifications from a validated workflow."

  alias Robine.Execution.Contracts.{Specification, Step}
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
    if Map.has_key?(workflow.jobs, job_id) do
      selected =
        if Map.get(input, :no_deps, false),
          do: MapSet.new([job_id]),
          else: dependencies(workflow.jobs, job_id, MapSet.new())

      {:ok, Enum.filter(workflow.order, &MapSet.member?(selected, &1))}
    else
      {:error, {:unknown_job, job_id, workflow.order}}
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
          metadata: %{"job_id" => job_id, "local" => true}
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

  defp omit_checkout(steps),
    do: Enum.reject(steps, &(&1.kind == :builtin and &1.value == "checkout"))

  defp execution_steps(steps, source_path) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, result} ->
      execution = %Step{name: step.name, kind: step.kind, value: step.value, with: step.with}

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
