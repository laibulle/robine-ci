defmodule RobineWeb.AuthControllerTest do
  use RobineWeb.ConnCase, async: false

  alias Robine.Adapters.Persistence.Postgres.Schemas.Session
  alias Robine.Repo

  test "renders sign-in and first-run setup", %{conn: conn} do
    assert conn |> get(~p"/sign-in") |> html_response(200) =~ "Sign in"

    assert conn |> recycle() |> get(~p"/setup") |> html_response(200) =~
             "Create the administrator"
  end

  test "bootstraps, signs in with a renewed session, and signs out", %{conn: conn} do
    conn =
      post(conn, ~p"/setup", %{
        "token" => "test-bootstrap-token",
        "email" => "admin@example.com",
        "password" => "a secure password"
      })

    assert redirected_to(conn) == ~p"/"
    assert token = get_session(conn, :session_token)
    assert Repo.aggregate(Session, :count) == 1

    conn = delete(recycle(conn), ~p"/sign-out")
    assert redirected_to(conn) == ~p"/sign-in"
    assert get_session(conn, :session_token) == nil

    [session] = Repo.all(Session)
    assert %DateTime{} = session.revoked_at
    assert :crypto.hash(:sha256, token) == session.token_digest
  end

  test "uses a generic error for invalid credentials", %{conn: conn} do
    conn = post(conn, ~p"/sign-in", %{"email" => "missing@example.com", "password" => "wrong"})
    assert redirected_to(conn) == ~p"/sign-in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password."
  end
end
