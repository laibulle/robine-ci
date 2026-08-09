defmodule Robine.Adapters.SourceControl.GitHubTelemetry do
  @moduledoc false

  @spec emit(atom(), integer(), {:ok, Req.Response.t()} | {:error, term()}) :: :ok
  def emit(method, started, result) do
    {outcome, status, measurements} = measurements(result)

    :telemetry.execute(
      [:robine, :github, :api, :request],
      Map.put(measurements, :duration, System.monotonic_time() - started),
      %{method: method, outcome: outcome, status: status}
    )

    Robine.Adapters.SourceControl.GitHubApiMonitor.record(measurements, %{
      method: method,
      outcome: outcome,
      status: status
    })

    :ok
  end

  defp measurements({:ok, %Req.Response{} = response}) do
    outcome = if response.status in 200..299, do: :ok, else: :http_error

    measurements =
      %{count: 1}
      |> put_header(response, :rate_limit_remaining, "x-ratelimit-remaining")
      |> put_header(response, :rate_limit_limit, "x-ratelimit-limit")
      |> put_header(response, :rate_limit_reset, "x-ratelimit-reset")

    {outcome, response.status, measurements}
  end

  defp measurements({:error, _reason}), do: {:transport_error, :transport, %{count: 1}}

  defp put_header(measurements, response, key, header) do
    value =
      case Map.get(response.headers, header) do
        [value | _rest] -> value
        value when is_binary(value) -> value
        _missing -> nil
      end

    case value && Integer.parse(value) do
      {integer, ""} -> Map.put(measurements, key, integer)
      _invalid -> measurements
    end
  end
end
