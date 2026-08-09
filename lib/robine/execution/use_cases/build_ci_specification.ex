defmodule Robine.Execution.UseCases.BuildCiSpecification do
  @moduledoc "Builds the in-memory runner contract from one persisted CI job input."

  alias Robine.Execution.Contracts.{Specification, Step}
  alias Robine.Execution.Domain.{CacheKey, SpecificationValidator}
  alias Robine.ExecutionContext
  alias Robine.Secrets

  @spec call(map(), ExecutionContext.t()) :: {:ok, Specification.t()} | {:error, term()}
  def call(
        %{persisted: raw, source_path: source_path},
        %ExecutionContext{
          actor: %{role: :administrator}
        } = context
      )
      when is_map(raw) and (is_binary(source_path) or is_nil(source_path)) do
    with image when is_binary(image) <- raw["image"],
         steps when is_list(steps) and steps != [] <- raw["steps"],
         steps = Enum.reject(steps, &checkout_step?/1),
         true <- steps != [],
         {:ok, secret_values} <- resolve_secrets(raw, context),
         {:ok, normalized_steps} <- resolve_steps(steps, source_path),
         specification = %Specification{
           version: 1,
           attempt_id: raw["attempt_id"],
           image: image,
           workspace: "/workspace",
           shell: raw["shell"] || "/bin/sh",
           timeout_ms: raw["timeout_ms"] || 1_200_000,
           source_path: source_path,
           env: raw["env"] || %{},
           secrets: secret_values,
           metadata: %{"idempotency_token" => raw["idempotency_token"]},
           steps: normalized_steps
         },
         :ok <- SpecificationValidator.validate(specification) do
      {:ok, specification}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_persisted_execution_specification}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp resolve_secrets(%{"secret_names" => []}, _context), do: {:ok, %{}}

  defp resolve_secrets(%{"secret_names" => names} = raw, context) when is_list(names) do
    Secrets.resolve_secrets(%{repository_id: raw["repository_id"], names: names}, context)
  end

  defp resolve_secrets(_raw, _context), do: {:ok, %{}}

  defp resolve_steps(steps, source_path) do
    Enum.reduce_while(steps, {:ok, []}, fn
      raw, {:ok, resolved} when is_map(raw) ->
        case resolve_step(step(raw), source_path) do
          {:ok, value} -> {:cont, {:ok, [value | resolved]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _raw, _result ->
        {:halt, {:error, :invalid_persisted_execution_specification}}
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      error -> error
    end
  end

  defp step(raw) do
    %Step{
      name: raw["name"],
      kind: kind(raw["kind"]),
      value: raw["value"],
      with: raw["with"] || %{}
    }
  end

  defp resolve_step(%Step{value: value, with: %{"key" => key}} = step, source_path)
       when value in ["cache/restore", "cache/save"] and is_binary(source_path) do
    case CacheKey.resolve(key, source_path) do
      {:ok, resolved} -> {:ok, %{step | with: Map.put(step.with, "key", resolved)}}
      error -> error
    end
  end

  defp resolve_step(%Step{value: value, with: %{"key" => key}} = step, nil)
       when value in ["cache/restore", "cache/save"] do
    if String.contains?(key, "${{"),
      do: {:error, {:cache_checksum, :checkout_required}},
      else: {:ok, step}
  end

  defp resolve_step(step, _source_path), do: {:ok, step}

  defp checkout_step?(%{"kind" => kind, "value" => "checkout"})
       when kind in [:builtin, "builtin"],
       do: true

  defp checkout_step?(_step), do: false

  defp kind(:run), do: :run
  defp kind("run"), do: :run
  defp kind(:builtin), do: :builtin
  defp kind("builtin"), do: :builtin
  defp kind(_unknown), do: :invalid
end
