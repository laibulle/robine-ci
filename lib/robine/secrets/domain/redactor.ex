defmodule Robine.Secrets.Domain.Redactor do
  @moduledoc "Stateful exact-value redactor safe across arbitrary chunk boundaries."
  @enforce_keys [:patterns, :tail]
  defstruct [:patterns, :tail]
  @type t :: %__MODULE__{patterns: [binary()], tail: binary()}

  @spec new([binary()]) :: {:ok, t()} | {:error, term()}
  def new(values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and byte_size(&1) >= 8)) do
      patterns =
        values
        |> Enum.flat_map(&[&1, Base.encode64(&1)])
        |> Enum.uniq()
        |> Enum.sort_by(&byte_size/1, :desc)

      {:ok, %__MODULE__{patterns: patterns, tail: <<>>}}
    else
      {:error, :secret_too_short}
    end
  end

  @spec push(t(), binary()) :: {binary(), t()}
  def push(%__MODULE__{} = redactor, chunk) when is_binary(chunk) do
    combined = redactor.tail <> chunk
    tail_length = incomplete_suffix_length(combined, redactor.patterns)
    emit_length = byte_size(combined) - tail_length
    emitted = binary_part(combined, 0, emit_length)
    tail = binary_part(combined, emit_length, tail_length)
    {replace_all(emitted, redactor.patterns), %{redactor | tail: tail}}
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
end
