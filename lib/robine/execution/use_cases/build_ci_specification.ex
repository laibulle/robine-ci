defmodule Robine.Execution.UseCases.BuildCiSpecification do
  @moduledoc "Builds the in-memory runner contract from one persisted CI job input."

  alias Robine.Execution.Contracts.{Service, Specification, Step}
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
         {:ok, services} <- resolve_services(raw["services"] || %{}, secret_values),
         {:ok, normalized_steps} <- resolve_steps(steps, source_path),
         {:ok, environment} <- build_environment(raw),
         specification = %Specification{
           version: 1,
           attempt_id: raw["attempt_id"],
           image: image,
           workspace: "/workspace",
           shell: raw["shell"] || "/bin/sh",
           timeout_ms: raw["timeout_ms"] || 1_200_000,
           source_path: source_path,
           env: environment,
           secrets: secret_values,
           services: services,
           metadata: %{
             "idempotency_token" => raw["idempotency_token"],
             "base_id" => raw["base_id"],
             "matrix_values" => raw["matrix_values"] || %{}
           },
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

  defp build_environment(raw) do
    environment = raw["env"] || %{}
    build_environment = raw["build_env"] || %{}

    if is_map(environment) and is_map(build_environment) and
         Enum.all?(build_environment, fn {name, value} ->
           is_binary(name) and is_binary(value)
         end) do
      {:ok, Map.merge(environment, build_environment)}
    else
      {:error, :invalid_build_environment}
    end
  end

  defp resolve_secrets(%{"secret_names" => []}, _context), do: {:ok, %{}}

  defp resolve_secrets(%{"resolved_secrets" => values}, _context) when is_map(values) do
    if Enum.all?(values, fn {name, value} -> is_binary(name) and is_binary(value) end),
      do: {:ok, values},
      else: {:error, :invalid_resolved_secrets}
  end

  defp resolve_secrets(%{"secret_names" => names} = raw, context) when is_list(names) do
    Secrets.resolve_secrets(%{repository_id: raw["repository_id"], names: names}, context)
  end

  defp resolve_secrets(_raw, _context), do: {:ok, %{}}

  defp resolve_services(services, secret_values) when is_map(services) do
    services
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {_id, raw}, {:ok, resolved} ->
      case resolve_service(raw, secret_values) do
        {:ok, service} -> {:cont, {:ok, [service | resolved]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      error -> error
    end
  end

  defp resolve_services(_services, _secret_values),
    do: {:error, :invalid_persisted_execution_specification}

  defp resolve_service(raw, secret_values) when is_map(raw) do
    with id when is_binary(id) <- raw["id"],
         image when is_binary(image) <- raw["image"],
         privileged when is_boolean(privileged) <- raw["privileged"] || false,
         env when is_map(env) <- raw["env"] || %{},
         secret_names when is_map(secret_names) <- raw["secret_env"] || %{},
         {:ok, secret_env} <- resolve_service_secrets(secret_names, secret_values),
         command when is_list(command) <- raw["command"] || [],
         {:ok, readiness} <- execution_readiness(raw["readiness"]) do
      {:ok,
       %Service{
         id: id,
         image: image,
         privileged: privileged,
         user: raw["user"],
         env: env,
         secret_env: secret_env,
         command: command,
         readiness: readiness
       }}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_persisted_execution_specification}
    end
  end

  defp resolve_service(_raw, _secret_values),
    do: {:error, :invalid_persisted_execution_specification}

  defp resolve_service_secrets(names, values) do
    Enum.reduce_while(names, {:ok, %{}}, fn {environment_name, secret_name}, {:ok, resolved} ->
      case Map.fetch(values, secret_name) do
        {:ok, value} -> {:cont, {:ok, Map.put(resolved, environment_name, value)}}
        :error -> {:halt, {:error, {:service_secret_missing, secret_name}}}
      end
    end)
  end

  defp execution_readiness(nil), do: {:ok, nil}

  defp execution_readiness(%{"tcp" => tcp, "timeout_ms" => timeout_ms}),
    do: {:ok, %{tcp: tcp, timeout_ms: timeout_ms}}

  defp execution_readiness(_invalid),
    do: {:error, :invalid_persisted_execution_specification}

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
      condition: condition(raw["condition"]),
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
  defp condition(nil), do: :success
  defp condition("success"), do: :success
  defp condition("failure"), do: :failure
  defp condition("always"), do: :always
  defp condition(_unknown), do: :invalid
end
