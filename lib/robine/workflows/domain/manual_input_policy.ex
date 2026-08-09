defmodule Robine.Workflows.Domain.ManualInputPolicy do
  @moduledoc "Pure validation and normalization of submitted manual workflow inputs."

  alias Robine.Workflows.Domain.ManualInput

  @spec normalize(%{optional(String.t()) => ManualInput.t()}, map()) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, term()}
  def normalize(definitions, submitted) when is_map(definitions) and is_map(submitted) do
    unknown = Map.keys(submitted) -- Map.keys(definitions)

    if unknown == [] do
      definitions
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while({:ok, %{}}, fn {id, definition}, {:ok, normalized} ->
        case value(definition, Map.get(submitted, id)) do
          {:ok, result} -> {:cont, {:ok, Map.put(normalized, id, result)}}
          {:error, reason} -> {:halt, {:error, {:manual_input, id, reason}}}
        end
      end)
    else
      {:error, {:manual_inputs_undeclared, Enum.sort(unknown)}}
    end
  end

  def normalize(_definitions, _submitted), do: {:error, :invalid_manual_inputs}

  defp value(%ManualInput{} = input, nil) do
    cond do
      not is_nil(input.default) -> {:ok, input.default}
      input.required -> {:error, :required}
      true -> {:ok, ""}
    end
  end

  defp value(%ManualInput{type: :string}, value), do: bounded_string(value)

  defp value(%ManualInput{type: :choice, options: options}, value) do
    with {:ok, normalized} <- bounded_string(value),
         true <- normalized in options do
      {:ok, normalized}
    else
      false -> {:error, :invalid_choice}
      error -> error
    end
  end

  defp value(%ManualInput{type: :boolean}, value) when value in [true, "true"], do: {:ok, "true"}

  defp value(%ManualInput{type: :boolean}, value) when value in [false, "false"],
    do: {:ok, "false"}

  defp value(%ManualInput{type: :boolean}, _value), do: {:error, :invalid_boolean}

  defp bounded_string(value)
       when is_binary(value) and byte_size(value) <= 1_024 do
    if String.valid?(value) and not String.contains?(value, ["\n", "\r", <<0>>]),
      do: {:ok, value},
      else: {:error, :invalid_string}
  end

  defp bounded_string(_value), do: {:error, :invalid_string}
end
