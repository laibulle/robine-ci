defmodule RobineWeb.SourceControlWebhookControllerTest do
  use RobineWeb.ConnCase, async: true

  test "deferred source-control webhook routes are not exposed", %{conn: conn} do
    for path <- ["/api/gitlab/webhooks", "/api/forgejo/webhooks"] do
      assert conn |> post(path, %{}) |> response(404)
    end
  end
end
