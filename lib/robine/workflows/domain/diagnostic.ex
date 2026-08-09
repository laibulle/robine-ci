defmodule Robine.Workflows.Domain.Diagnostic do
  @moduledoc "Stable source diagnostic returned by workflow validation."

  @enforce_keys [:code, :message, :path]
  defstruct [:code, :message, :path, :line, :column, severity: :error]

  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          path: [String.t() | non_neg_integer()],
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          severity: :error | :warning
        }

  @spec error(String.t(), String.t(), list()) :: t()
  def error(code, message, path), do: %__MODULE__{code: code, message: message, path: path}

  @spec warning(String.t(), String.t(), list()) :: t()
  def warning(code, message, path) do
    %__MODULE__{code: code, message: message, path: path, severity: :warning}
  end

  @spec locate(t(), map()) :: t()
  def locate(%__MODULE__{} = diagnostic, locations) when is_map(locations) do
    case nearest_location(diagnostic.path, locations) do
      %{line: line, column: column} -> %{diagnostic | line: line, column: column}
      nil -> diagnostic
    end
  end

  defp nearest_location(path, locations) do
    case Map.get(locations, path) do
      nil when path != [] -> nearest_location(Enum.drop(path, -1), locations)
      location -> location
    end
  end
end
