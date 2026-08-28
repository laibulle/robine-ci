defmodule RobineWeb.AdminApiTokenLiveTest do
  use RobineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Robine.Adapters.Persistence.Postgres.Schemas.{ApiToken, User}
  alias Robine.Repo

  test "creates, reveals once, lists, and revokes a global upload token", %{conn: conn} do
    conn = bootstrap(conn)

    assert {:ok, view, _html} =
             live(conn, ~p"/admin/api-tokens")

    assert has_element?(view, "#api-token-form")
    assert has_element?(view, "#api-tokens-empty")

    view
    |> form("#api-token-form",
      api_token: %{name: "Mac release upload", expires_in_days: "30"}
    )
    |> render_submit()

    persisted = Repo.one!(ApiToken)
    assert persisted.name == "Mac release upload"
    assert persisted.permissions == ["artifacts:write"]
    assert has_element?(view, "#api-token-one-time-reveal")
    assert has_element?(view, "#new-api-token-value[value^='rbn_art_']")
    assert has_element?(view, "[id$='#{persisted.id}']")
    assert has_element?(view, "#api-token-count", "1 token")

    view |> element("#dismiss-api-token") |> render_click()
    refute has_element?(view, "#api-token-one-time-reveal")

    view
    |> element("#revoke-api-token-#{persisted.id}")
    |> render_click()

    assert Repo.get!(ApiToken, persisted.id).revoked_at
    refute has_element?(view, "#revoke-api-token-#{persisted.id}")
  end

  test "keeps the token-management route unavailable to viewers", %{conn: conn} do
    conn = bootstrap(conn)

    user = Repo.one!(User)
    user |> Ecto.Changeset.change(role: :viewer) |> Repo.update!()

    assert {:error, {:redirect, %{to: "/pipelines"}}} =
             live(conn, ~p"/admin/api-tokens")
  end

  defp bootstrap(conn) do
    post(conn, ~p"/setup", %{
      "token" => "test-bootstrap-token",
      "email" => "admin@example.com",
      "password" => "a secure password"
    })
  end
end
