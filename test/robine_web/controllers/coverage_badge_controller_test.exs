defmodule RobineWeb.CoverageBadgeControllerTest do
  use RobineWeb.ConnCase, async: false

  test "serves a cacheable neutral SVG when no retained measurement exists", %{conn: conn} do
    conn = get(conn, ~p"/badges/github/missing/repository/coverage.svg")

    assert response(conn, 200) =~ "coverage: unknown"
    assert get_resp_header(conn, "content-type") == ["image/svg+xml; charset=utf-8"]

    assert get_resp_header(conn, "cache-control") ==
             ["public, max-age=60, stale-while-revalidate=300"]
  end
end
