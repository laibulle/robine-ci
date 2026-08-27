defmodule RobineWeb.RunnerDeploymentControllerTest do
  use RobineWeb.ConnCase, async: true

  test "artifact and secret transfer require an authenticated assigned runner", %{conn: conn} do
    deployment_id = Ecto.UUID.generate()

    artifact = get(conn, ~p"/api/v1/runners/deployments/#{deployment_id}/artifact")
    assert %{"error" => "unauthorized"} = json_response(artifact, 401)
    assert get_resp_header(artifact, "cache-control") == ["max-age=0, private, must-revalidate"]

    secrets = get(recycle(conn), ~p"/api/v1/runners/deployments/#{deployment_id}/secrets")
    assert %{"error" => "unauthorized"} = json_response(secrets, 401)
  end
end
