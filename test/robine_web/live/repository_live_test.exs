defmodule RobineWeb.RepositoryLiveTest do
  use RobineWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Robine.Repositories
  alias Robine.Adapters.Persistence.Postgres.Schemas.{GitHubRepository, User}
  alias Robine.Repo
  alias Robine.Runtime.Dependencies

  defmodule RepositoryDiscoveryGitHub do
    @behaviour Robine.Repositories.Ports.GitHub

    @impl true
    def available_repositories do
      {:ok,
       [
         %{
           provider_id: 73_001,
           installation_id: 42,
           full_name: "acme/discovered",
           private: true
         }
       ]}
    end

    @impl true
    def workflow_files(_repository, _sha), do: {:ok, []}
    @impl true
    def source_files(_repository, _sha), do: {:ok, []}
    @impl true
    def upsert_check(_repository, _check), do: {:ok, 1}
    @impl true
    def installation_permissions(_repository), do: {:ok, %{}}
  end

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

  test "discovers GitHub App access and trusts only an exact server-verified selection", %{
    conn: conn
  } do
    previous_adapter = Application.fetch_env!(:robine, :github_adapter)
    Application.put_env(:robine, :github_adapter, RepositoryDiscoveryGitHub)
    on_exit(fn -> Application.put_env(:robine, :github_adapter, previous_adapter) end)

    conn = signed_in_conn(conn)
    assert {:ok, view, html} = live(conn, ~p"/repositories")
    assert html =~ "No GitHub access has been queried"

    html = view |> element("#discover-github-repositories") |> render_click()
    assert html =~ "acme/discovered"
    assert html =~ "Installation 42"

    html =
      view
      |> element("#available-repository-73001 button")
      |> render_click(%{
        "provider_id" => "999",
        "installation_id" => "42",
        "full_name" => "acme/discovered"
      })

    assert html =~ "GitHub no longer grants"
    refute html =~ "is now trusted"

    html =
      view
      |> element("#available-repository-73001 button")
      |> render_click()

    assert html =~ "acme/discovered is now trusted"
    assert has_element?(view, "[id^='repository-']")
    refute has_element?(view, "#available-repository-73001")
  end

  test "viewer route and forged-event boundaries remain read-only", %{conn: conn} do
    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "viewer-boundary")

    assert {:ok, repository} =
             Repositories.register_github_repository(
               %{provider_id: 80_001, installation_id: 8, full_name: "acme/read-only"},
               context
             )

    admin = Repo.one!(User)
    admin |> Ecto.Changeset.change(role: :viewer) |> Repo.update!()

    assert {:error, {:redirect, %{to: "/pipelines"}}} =
             live(conn, ~p"/repositories/#{repository.id}/secrets")

    assert {:ok, index, index_html} = live(conn, ~p"/repositories")
    refute index_html =~ "Refresh installations"
    assert render_hook(index, "discover", %{}) =~ "Only administrators can connect repositories."

    assert render_hook(index, "trust", %{
             "provider_id" => "80_002",
             "installation_id" => "8",
             "full_name" => "acme/forged"
           }) =~ "The repository could not be trusted."

    assert Repo.aggregate(GitHubRepository, :count) == 1

    assert {:ok, show, show_html} = live(conn, ~p"/repositories/#{repository.id}")
    refute show_html =~ "Check permissions"

    assert render_hook(show, "check-github-installation", %{}) =~
             "You do not have permission to check GitHub installations."
  end

  defp signed_in_conn(conn) do
    post(conn, ~p"/setup", %{
      "token" => "test-bootstrap-token",
      "email" => "admin@example.com",
      "password" => "a secure password"
    })
  end
end
