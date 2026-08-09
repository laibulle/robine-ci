defmodule RobineWeb.RepositoryLiveTest do
  use RobineWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Robine.Repositories
  alias Robine.Runtime.Dependencies

  test "browses a trusted repository and manages write-only secrets", %{conn: conn} do
    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "repository-live")

    assert {:ok, repository} =
             Repositories.register_github_repository(
               %{provider_id: 91_919_191, installation_id: 42, full_name: "acme/widget"},
               context
             )

    assert {:ok, index, html} = live(conn, ~p"/repositories")
    assert html =~ "acme/widget"
    assert has_element?(index, "#repository-#{repository.id}")

    assert {:ok, show, html} = live(conn, ~p"/repositories/#{repository.id}")
    assert html =~ "No valid workflow has run yet"
    assert html =~ "Manage secrets"
    assert html =~ "Metadata read, Contents read, Checks write"
    assert has_element?(show, "#check-github-installation", "Check permissions")

    assert {:ok, secrets, html} = live(conn, ~p"/repositories/#{repository.id}/secrets")
    assert html =~ "write-only"

    html =
      secrets
      |> form("#secret-form", %{"name" => "REGISTRY_TOKEN", "value" => "super-secret-value"})
      |> render_submit()

    assert html =~ "REGISTRY_TOKEN"
    refute html =~ "super-secret-value"
  end

  defp signed_in_conn(conn) do
    post(conn, ~p"/setup", %{
      "token" => "test-bootstrap-token",
      "email" => "admin@example.com",
      "password" => "a secure password"
    })
  end
end
