defmodule RobineWeb.RunnerInstallerTest do
  use RobineWeb.ConnCase, async: true

  test "serves the packaged POSIX installer publicly", %{conn: conn} do
    conn = get(conn, "/install/rbe.sh")
    installer = response(conn, :ok)

    assert installer =~ "#!/bin/bash"
    assert installer =~ "releases/latest"
    assert installer =~ "shasum -a 256"
    assert installer =~ "sha256sum"
    assert installer =~ "Linux)"
    refute installer =~ "ROBINE_RUNNER_ENROLLMENT_TOKEN"
  end

  test "serves the packaged Windows installer publicly", %{conn: conn} do
    conn = get(conn, "/install/rbe.ps1")
    installer = response(conn, :ok)

    assert installer =~ "Set-StrictMode"
    assert installer =~ "robine-runner-windows-multiarch.tar.gz"
    assert installer =~ "Get-FileHash -Algorithm SHA256"
    refute installer =~ "ROBINE_RUNNER_ENROLLMENT_TOKEN='"
  end
end
