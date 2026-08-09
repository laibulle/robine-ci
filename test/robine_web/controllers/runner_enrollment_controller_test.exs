defmodule RobineWeb.RunnerEnrollmentControllerTest do
  use RobineWeb.ConnCase, async: false

  alias Robine.Runners
  alias Robine.Runtime.Dependencies

  test "exchanges an enrollment token exactly once", %{conn: conn} do
    admin_context =
      Dependencies.context(%{id: "admin-http", role: :administrator}, Ecto.UUID.generate())

    assert {:ok, enrollment} = Runners.create_enrollment_token(%{}, admin_context)

    conn =
      post(conn, ~p"/api/v1/runners/enroll", %{
        "token" => enrollment.token,
        "name" => "remote-http-1"
      })

    assert %{"runner_id" => runner_id, "credential" => "rrc_" <> _} =
             json_response(conn, :created)

    replay =
      post(build_conn(), ~p"/api/v1/runners/enroll", %{
        "token" => enrollment.token,
        "name" => "remote-http-2"
      })

    assert json_response(replay, :unauthorized) == %{"error" => "invalid enrollment token"}
    assert Ecto.UUID.cast(runner_id) != :error
  end

  test "does not distinguish unknown and malformed enrollment tokens", %{conn: conn} do
    for token <- ["rbe_" <> String.duplicate("a", 43), "malformed"] do
      response = post(conn, ~p"/api/v1/runners/enroll", %{"token" => token, "name" => "runner"})
      assert json_response(response, :unauthorized) == %{"error" => "invalid enrollment token"}
    end
  end

  test "rate limits repeated enrollment failures" do
    remote_ip = {10, 99, 1, rem(System.unique_integer([:positive]), 250) + 1}
    params = %{"token" => "rbe_" <> String.duplicate("z", 43), "name" => "runner"}

    for _attempt <- 1..10 do
      conn = %{build_conn() | remote_ip: remote_ip}
      assert conn |> post(~p"/api/v1/runners/enroll", params) |> json_response(:unauthorized)
    end

    limited = %{build_conn() | remote_ip: remote_ip} |> post(~p"/api/v1/runners/enroll", params)

    assert json_response(limited, :too_many_requests) == %{
             "error" => "too many enrollment attempts"
           }

    assert get_resp_header(limited, "retry-after") == ["60"]
  end
end
