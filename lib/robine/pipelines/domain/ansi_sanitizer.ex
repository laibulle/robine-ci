defmodule Robine.Pipelines.Domain.AnsiSanitizer do
  @moduledoc "Removes terminal control sequences while preserving printable log text."

  @csi ~r/\x1B\[[0-?]*[ -\/]*[@-~]/
  @osc ~r/\x1B\][^\x07]*(?:\x07|\x1B\\)/
  @single ~r/\x1B[@-_]/

  @spec strip(String.t()) :: String.t()
  def strip(value) when is_binary(value) do
    value
    |> String.replace(@osc, "")
    |> String.replace(@csi, "")
    |> String.replace(@single, "")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
  end
end
