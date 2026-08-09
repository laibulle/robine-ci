defmodule RobineWeb.AdminLiveTest do
  use RobineWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Robine.Adapters.Persistence.Postgres.Schemas.User
  alias Robine.Repo

  test "shows secret-free identity configuration and protects the last administrator", %{
    conn: conn
  } do
    conn = signed_in_conn(conn)
    admin = Repo.one!(User)

    assert {:ok, view, html} = live(conn, ~p"/admin")
    assert html =~ "Administration"
    assert html =~ "Optional SSO is disabled"
    assert html =~ "Instance health"
    assert html =~ "PostgreSQL"
    assert html =~ "Durable queue"
    assert html =~ "Blob storage"
    assert html =~ "Retention policy"
    assert html =~ "30 days"
    assert html =~ "admin@example.com"
    refute html =~ "test-bootstrap-token"

    html =
      view
      |> form("#role-#{admin.id}", %{"user_id" => admin.id, "role" => "viewer"})
      |> render_change()

    assert html =~ "Create another usable administrator"
    assert Repo.get!(User, admin.id).role == :administrator
  end

  test "redirects non-administrators from instance administration", %{conn: conn} do
    conn = signed_in_conn(conn)
    admin = Repo.one!(User)
    admin |> Ecto.Changeset.change(role: :maintainer) |> Repo.update!()

    assert {:error, {:redirect, %{to: "/pipelines"}}} = live(conn, ~p"/admin")
  end

  defp signed_in_conn(conn) do
    post(conn, ~p"/setup", %{
      "token" => "test-bootstrap-token",
      "email" => "admin@example.com",
      "password" => "a secure password"
    })
  end
end
