defmodule RobineWeb.MetricsControllerTest do
  use RobineWeb.ConnCase, async: false

  test "requires the configured bearer token", %{conn: conn} do
    assert conn |> get(~p"/metrics") |> response(401) == "Unauthorized"

    assert conn
           |> put_req_header("authorization", "Bearer wrong-token")
           |> get(~p"/metrics")
           |> response(401) == "Unauthorized"
  end

  test "returns a Prometheus scrape without exposing the token", %{conn: conn} do
    :telemetry.execute([:robine, :queue], %{depth: 3, oldest_age: 7}, %{})

    conn =
      conn
      |> put_req_header("authorization", "Bearer test-metrics-token")
      |> get(~p"/metrics")

    body = response(conn, 200)

    assert get_resp_header(conn, "content-type") == [
             "text/plain; version=0.0.4; charset=utf-8"
           ]

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert body =~ "robine_queue_depth"
    assert body =~ " 3"
    refute body =~ "test-metrics-token"
  end

  test "looks absent when metrics export is disabled", %{conn: conn} do
    previous = Application.get_env(:robine, :metrics_token_hash)
    Application.delete_env(:robine, :metrics_token_hash)

    on_exit(fn -> Application.put_env(:robine, :metrics_token_hash, previous) end)

    assert conn
           |> put_req_header("authorization", "Bearer test-metrics-token")
           |> get(~p"/metrics")
           |> response(404) == "Not Found"
  end
end
