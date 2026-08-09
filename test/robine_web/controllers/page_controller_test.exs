defmodule RobineWeb.PageControllerTest do
  use RobineWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    document = conn |> html_response(200) |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query("h1") |> LazyHTML.text() =~ "Build with speed."
    assert document |> LazyHTML.query("a[href='/sign-in']") |> Enum.any?()

    [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "script-src 'self'"
    refute policy =~ "unsafe-eval"
  end
end
