defmodule RobineWeb.MetricsController do
  use RobineWeb, :controller

  @prometheus_content_type "text/plain; version=0.0.4; charset=utf-8"

  def index(conn, _params) do
    with {:ok, expected_hash} <- Application.fetch_env(:robine, :metrics_token_hash),
         {:ok, supplied_token} <- bearer_token(conn),
         true <- secure_token?(supplied_token, expected_hash) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type(@prometheus_content_type, nil)
      |> send_resp(200, TelemetryMetricsPrometheus.Core.scrape(:robine_prometheus))
    else
      :error -> send_resp(conn, 404, "Not Found")
      _unauthorized -> unauthorized(conn)
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 -> {:ok, token}
      _other -> {:error, :missing_credentials}
    end
  end

  defp secure_token?(token, expected_hash) when is_binary(expected_hash) do
    Plug.Crypto.secure_compare(:crypto.hash(:sha256, token), expected_hash)
  end

  defp secure_token?(_token, _expected_hash), do: false

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="Robine metrics"))
    |> send_resp(401, "Unauthorized")
  end
end
