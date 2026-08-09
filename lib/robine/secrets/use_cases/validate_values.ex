defmodule Robine.Secrets.UseCases.ValidateValues do
  @moduledoc "Validates secret-value masking bounds without persisting or exposing values."

  alias Robine.Secrets.Domain.ValuePolicy

  @spec call(map()) :: :ok | {:error, term()}
  def call(%{values: values}) when is_map(values) do
    values
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn
      {name, value}, :ok when is_binary(name) ->
        case ValuePolicy.validate(value) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:invalid_secret_value, name, reason}}}
        end

      _entry, :ok ->
        {:halt, {:error, :invalid_secret_values}}
    end)
  end

  def call(_input), do: {:error, :invalid_secret_values}
end
