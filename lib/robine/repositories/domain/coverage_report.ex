defmodule Robine.Repositories.Domain.CoverageReport do
  @moduledoc "Parses the bounded coverage marker emitted by trusted workflows."

  @marker ~r/(?:\A|\n)ROBINE_COVERAGE total=(\d{1,3}(?:\.\d+)?) threshold=(\d{1,3}(?:\.\d+)?) report=([a-zA-Z0-9][a-zA-Z0-9._-]{0,127})(?:\n|\z)/

  @spec parse(String.t()) :: {:ok, map()} | :error
  def parse(content) when is_binary(content) do
    case Regex.run(@marker, content) do
      [_marker, total, threshold, report] ->
        with {:ok, total_value} <- percentage(total),
             {:ok, threshold_value} <- percentage(threshold) do
          {:ok,
           %{
             total: total,
             total_value: total_value,
             threshold: threshold,
             threshold_value: threshold_value,
             report: report
           }}
        else
          :error -> :error
        end

      nil ->
        :error
    end
  end

  def parse(_content), do: :error

  defp percentage(value) do
    case Float.parse(value) do
      {parsed, ""} when parsed >= 0.0 and parsed <= 100.0 -> {:ok, parsed}
      _invalid -> :error
    end
  end
end
