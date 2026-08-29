defmodule RobineWeb.RunnerInstallerTest do
  use RobineWeb.ConnCase, async: true

  test "serves the packaged macOS installer publicly", %{conn: conn} do
    conn = get(conn, "/install/rbe.sh")
    installer = response(conn, :ok)

    assert installer =~ "#!/bin/bash"
    assert installer =~ "releases/latest"
    assert installer =~ "shasum -a 256"
    refute installer =~ "ROBINE_RUNNER_ENROLLMENT_TOKEN"
  end
end
