defmodule Robine.Execution.Domain.SpecificationValidator do
  @moduledoc "Pure validation for normalized execution specifications."

  alias Robine.Execution.Contracts.{Service, Specification, Step}

  @max_timeout_ms 86_400_000
  @max_steps 256

  @spec validate(Specification.t()) :: :ok | {:error, term()}
  def validate(%Specification{} = specification) do
    with :ok <- version(specification.version),
         :ok <- identifier(specification.attempt_id),
         :ok <- nonempty(:image, specification.image),
         :ok <- workspace(specification.workspace),
         :ok <- shell(specification.shell),
         :ok <- timeout(specification.timeout_ms),
         :ok <- source_path(specification.source_path),
         :ok <- string_map(:env, specification.env),
         :ok <- string_map(:secrets, specification.secrets),
         :ok <- services(specification.services),
         :ok <- steps(specification.steps) do
      :ok
    end
  end

  def validate(_value), do: {:error, {:invalid_specification, :type}}

  defp version(1), do: :ok
  defp version(value), do: {:error, {:invalid_specification, :version, value}}

  defp identifier(value) when is_binary(value) and byte_size(value) in 1..128, do: :ok
  defp identifier(_value), do: {:error, {:invalid_specification, :attempt_id}}

  defp nonempty(_field, value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp nonempty(field, _value), do: {:error, {:invalid_specification, field}}

  defp workspace(value) when is_binary(value) do
    if String.starts_with?(value, "/") and not String.contains?(value, ".."),
      do: :ok,
      else: {:error, {:invalid_specification, :workspace}}
  end

  defp workspace(_value), do: {:error, {:invalid_specification, :workspace}}

  defp shell(value) when value in ["/bin/sh", "/bin/bash"], do: :ok
  defp shell(_value), do: {:error, {:invalid_specification, :shell}}

  defp timeout(value) when is_integer(value) and value > 0 and value <= @max_timeout_ms, do: :ok
  defp timeout(_value), do: {:error, {:invalid_specification, :timeout_ms}}

  defp source_path(nil), do: :ok

  defp source_path(value) when is_binary(value) do
    if Path.type(value) == :absolute,
      do: :ok,
      else: {:error, {:invalid_specification, :source_path}}
  end

  defp source_path(_value), do: {:error, {:invalid_specification, :source_path}}

  defp string_map(_field, value) when map_size(value) == 0, do: :ok

  defp string_map(field, value) when is_map(value) do
    if Enum.all?(value, fn {key, entry} ->
         is_binary(key) and key =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/ and is_binary(entry)
       end),
       do: :ok,
       else: {:error, {:invalid_specification, field}}
  end

  defp string_map(field, _value), do: {:error, {:invalid_specification, field}}

  defp services(services) when is_list(services) and length(services) <= 8 do
    ids = Enum.map(services, &Map.get(&1, :id))

    if Enum.all?(services, &valid_service?/1) and Enum.uniq(ids) == ids,
      do: :ok,
      else: {:error, {:invalid_specification, :services}}
  end

  defp services(_services), do: {:error, {:invalid_specification, :services}}

  defp valid_service?(%Service{} = service) do
    service.id =~ ~r/\A[a-z][a-z0-9_-]{0,62}\z/ and nonempty_string?(service.image) and
      valid_service_user?(service.user) and
      valid_service_map?(service.env) and valid_service_map?(service.secret_env) and
      is_list(service.command) and length(service.command) <= 32 and
      Enum.all?(service.command, &(is_binary(&1) and byte_size(&1) in 1..4_096)) and
      valid_readiness?(service.readiness)
  end

  defp valid_service?(_service), do: false

  defp valid_service_user?(nil), do: true

  defp valid_service_user?(user) when is_binary(user) and byte_size(user) in 1..128,
    do: Regex.match?(~r/\A[a-zA-Z0-9_.-]+(?::[a-zA-Z0-9_.-]+)?\z/, user)

  defp valid_service_user?(_user), do: false

  defp valid_service_map?(value) when is_map(value) and map_size(value) <= 64 do
    Enum.all?(value, fn {key, entry} ->
      is_binary(key) and Regex.match?(~r/\A[A-Z_][A-Z0-9_]*\z/, key) and is_binary(entry)
    end)
  end

  defp valid_service_map?(_value), do: false
  defp valid_readiness?(nil), do: true

  defp valid_readiness?(%{tcp: port, timeout_ms: timeout}) do
    is_integer(port) and port in 1..65_535 and is_integer(timeout) and timeout in 1_000..120_000
  end

  defp valid_readiness?(_value), do: false

  defp steps(steps) when is_list(steps) and steps != [] and length(steps) <= @max_steps do
    with true <- Enum.all?(steps, &match?(%Step{}, &1)),
         true <- Enum.all?(steps, &valid_step?/1),
         names = Enum.map(steps, & &1.name),
         true <- Enum.uniq(names) == names do
      :ok
    else
      _ -> {:error, {:invalid_specification, :steps}}
    end
  end

  defp steps(_steps), do: {:error, {:invalid_specification, :steps}}

  defp valid_step?(%Step{
         name: name,
         kind: kind,
         value: value,
         condition: condition,
         with: options
       })
       when kind in [:run, :builtin],
       do:
         nonempty_string?(name) and nonempty_string?(value) and
           condition in [:success, :failure, :always] and is_map(options)

  defp valid_step?(_step), do: false

  defp nonempty_string?(value), do: is_binary(value) and byte_size(value) > 0
end
