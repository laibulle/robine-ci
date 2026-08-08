defmodule Robine.Execution.Domain.SpecificationValidator do
  @moduledoc "Pure validation for normalized execution specifications."

  alias Robine.Execution.Contracts.{Specification, Step}

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
         :ok <- string_map(:env, specification.env),
         :ok <- string_map(:secrets, specification.secrets),
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

  defp string_map(_field, value) when map_size(value) == 0, do: :ok

  defp string_map(field, value) when is_map(value) do
    if Enum.all?(value, fn {key, entry} ->
         is_binary(key) and key =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/ and is_binary(entry)
       end),
       do: :ok,
       else: {:error, {:invalid_specification, field}}
  end

  defp string_map(field, _value), do: {:error, {:invalid_specification, field}}

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

  defp valid_step?(%Step{name: name, kind: :run, value: value}),
    do: nonempty_string?(name) and nonempty_string?(value)

  defp valid_step?(%Step{name: name, kind: :builtin, value: value, with: options}),
    do: nonempty_string?(name) and nonempty_string?(value) and is_map(options)

  defp valid_step?(_step), do: false

  defp nonempty_string?(value), do: is_binary(value) and byte_size(value) > 0
end
