defmodule RobineWeb.HealthControllerTest do
  use RobineWeb.ConnCase, async: false

  test "liveness is cheap and secret-free", %{conn: conn} do
    conn = get(conn, ~p"/health/live")

    assert %{"status" => "ok"} = json_response(conn, 200)
  end

  test "readiness exposes no component or configuration details", %{conn: conn} do
    conn = get(conn, ~p"/health/ready")
    body = response(conn, conn.status)

    assert conn.status in [200, 503]
    assert %{"status" => status, "checked_at" => checked_at} = Jason.decode!(body)
    assert status in ["ready", "not_ready"]
    assert {:ok, _, _} = DateTime.from_iso8601(checked_at)
    refute body =~ "PostgreSQL"
    refute body =~ "Docker"
    refute body =~ "test-bootstrap-token"
    refute body =~ "github"
  end
end
