defmodule Robine.Secrets.Domain.Redactor do
  @moduledoc "Stateful exact-value redactor safe across arbitrary chunk boundaries."
  alias Robine.Secrets.Domain.ValuePolicy

  @derive {Inspect, except: [:patterns, :tail]}
  @enforce_keys [:patterns, :tail]
  defstruct [:patterns, :tail]
  @type t :: %__MODULE__{patterns: [binary()], tail: binary()}

  @spec new([binary()]) :: {:ok, t()} | {:error, term()}
  def new(values) when is_list(values) do
    case Enum.find_value(values, &validation_error/1) do
      nil ->
        patterns =
          values
          |> Enum.flat_map(&ValuePolicy.variants/1)
          |> Enum.uniq()
          |> Enum.sort_by(&byte_size/1, :desc)

        {:ok, %__MODULE__{patterns: patterns, tail: <<>>}}

      reason ->
        {:error, reason}
    end
  end

  @spec push(t(), binary()) :: {binary(), t()}
  def push(%__MODULE__{} = redactor, chunk) when is_binary(chunk) do
    redacted = replace_all(redactor.tail <> chunk, redactor.patterns)
    tail_length = incomplete_suffix_length(redacted, redactor.patterns)
    emit_length = byte_size(redacted) - tail_length
    emitted = binary_part(redacted, 0, emit_length)
    tail = binary_part(redacted, emit_length, tail_length)
    {emitted, %{redactor | tail: tail}}
  end

  @spec finish(t()) :: binary()
  def finish(%__MODULE__{} = redactor), do: replace_all(redactor.tail, redactor.patterns)

  defp incomplete_suffix_length(binary, patterns) do
    patterns
    |> Enum.flat_map(fn pattern ->
      max_length = min(byte_size(pattern) - 1, byte_size(binary))

      if max_length < 1,
        do: [],
        else:
          for(
            length <- 1..max_length,
            suffix = binary_part(binary, byte_size(binary) - length, length),
            binary_part(pattern, 0, length) == suffix,
            do: length
          )
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp replace_all(binary, patterns),
    do: Enum.reduce(patterns, binary, &String.replace(&2, &1, "[REDACTED]"))

  defp validation_error(value) do
    case ValuePolicy.validate(value) do
      :ok -> nil
      {:error, reason} -> reason
    end
  end
end
