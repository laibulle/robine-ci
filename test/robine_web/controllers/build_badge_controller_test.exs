defmodule RobineWeb.BuildBadgeControllerTest do
  use RobineWeb.ConnCase, async: false

  test "serves a cacheable neutral SVG when the repository is unknown", %{conn: conn} do
    conn = get(conn, ~p"/badges/github/missing/repository/build.svg")

    assert response(conn, 200) =~ "build: unknown"
    assert get_resp_header(conn, "content-type") == ["image/svg+xml; charset=utf-8"]

    assert get_resp_header(conn, "cache-control") ==
             ["public, max-age=30, stale-while-revalidate=120"]
  end
end
