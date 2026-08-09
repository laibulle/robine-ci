defmodule RobineWeb.PageControllerTest do
  use RobineWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
    [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "script-src 'self'"
    refute policy =~ "unsafe-eval"
  end
end
