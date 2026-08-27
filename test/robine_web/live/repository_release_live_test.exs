defmodule RobineWeb.RepositoryReleaseLiveTest do
  use RobineWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    AuditEvent,
    Publication,
    PublicationPolicy,
    User
  }

  alias Robine.{Publications, Repo, Repositories}
  alias Robine.Runtime.Dependencies

  test "administrator enables public releases and sees immutable release provenance", %{
    conn: conn
  } do
    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "release-live")

    assert {:ok, repository} =
             Repositories.register_github_repository(
               %{provider_id: 77_001, installation_id: 42, full_name: "private/widget"},
               context
             )

    assert {:ok, repository_view, _html} = live(conn, ~p"/repositories/#{repository.id}")
    assert has_element?(repository_view, "#repository-releases", "Public releases")

    assert {:ok, releases, _html} = live(conn, ~p"/repositories/#{repository.id}/releases")
    assert has_element?(releases, "#publication-policy-form")
    assert has_element?(releases, "#release-count", "0 releases")
    assert has_element?(releases, "#publications", "No public release yet")

    releases
    |> form("#publication-policy-form", %{
      "policy" => %{"enabled" => "true", "public_slug" => "widget-downloads"}
    })
    |> render_submit()

    assert has_element?(releases, "#public-release-prefix", "/downloads/widget-downloads/…")
    assert Repo.get_by!(PublicationPolicy, repository_id: repository.id).enabled

    audit = Repo.get_by!(AuditEvent, action: "publication.policy_configured")
    assert audit.target_id == repository.id
    assert audit.metadata["enabled"]
    assert audit.metadata["public_slug"] == "widget-downloads"

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Publication.changeset(%Publication{}, %{
      id: Ecto.UUID.generate(),
      repository_id: repository.id,
      release: "v1.2.0",
      filename: "widget-linux-amd64.tar.gz",
      content_type: "application/gzip",
      digest: String.duplicate("a", 64),
      size: 2_097_152,
      status: :published,
      source_commit: String.duplicate("b", 40),
      source_tag: "v1.2.0",
      public_url: "https://downloads.example/widget/v1.2.0/widget-linux-amd64.tar.gz",
      published_at: now,
      inserted_at: now,
      updated_at: now
    })
    |> Repo.insert!()

    assert {:ok, release_history, _html} = live(conn, ~p"/repositories/#{repository.id}/releases")
    assert has_element?(release_history, "#release-count", "1 release")
    assert has_element?(release_history, "#publications article", "widget-linux-amd64.tar.gz")
    assert has_element?(release_history, "#publications article", "v1.2.0")

    assert has_element?(
             release_history,
             "#publications a[href='https://downloads.example/widget/v1.2.0/widget-linux-amd64.tar.gz']",
             "Versioned"
           )

    assert has_element?(
             release_history,
             "#latest-release-#{Repo.one!(Publication).id}[href='/downloads/widget-downloads/latest/widget-linux-amd64.tar.gz']",
             "Latest"
           )
  end

  test "public latest redirects to the newest stable publication without caching", %{conn: conn} do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "release-latest")

    assert {:ok, repository} =
             Repositories.register_github_repository(
               %{provider_id: 77_003, installation_id: 42, full_name: "private/latest"},
               context
             )

    assert {:ok, _policy} =
             Publications.configure_repository(
               %{repository_id: repository.id, enabled: true, public_slug: "latest-widget"},
               context
             )

    insert_publication(
      repository.id,
      "v1.2.0",
      "https://cdn.example/widget/v1.2.0/app.tar.gz",
      -4
    )

    insert_publication(
      repository.id,
      "v2.0.0-rc.1",
      "https://cdn.example/widget/v2.0.0-rc.1/app.tar.gz",
      -2
    )

    expected_url = "https://cdn.example/widget/v1.3.0/app.tar.gz"
    insert_publication(repository.id, "v1.3.0", expected_url, -3)

    insert_publication(
      repository.id,
      "v1.4.0",
      "https://cdn.example/widget/v1.4.0/app.tar.gz",
      -1,
      :withdrawn
    )

    insert_publication(
      repository.id,
      "v1.5.0",
      "https://cdn.example/widget/v1.5.0/app.tar.gz",
      0,
      :failed
    )

    insert_publication(
      repository.id,
      "v1.6.0",
      "https://cdn.example/widget/v1.6.0/app.tar.gz",
      1,
      :staged
    )

    response = get(conn, ~p"/downloads/latest-widget/latest/app.tar.gz")

    assert redirected_to(response, 302) == expected_url
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
  end

  test "public latest returns not found when no stable publication exists", %{conn: conn} do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "release-no-latest")

    assert {:ok, repository} =
             Repositories.register_github_repository(
               %{provider_id: 77_004, installation_id: 42, full_name: "private/prerelease-only"},
               context
             )

    assert {:ok, _policy} =
             Publications.configure_repository(
               %{repository_id: repository.id, enabled: true, public_slug: "preview-widget"},
               context
             )

    insert_publication(
      repository.id,
      "v2.0.0-rc.1",
      "https://cdn.example/widget/v2.0.0-rc.1/app.tar.gz",
      -1
    )

    response = get(conn, ~p"/downloads/preview-widget/latest/app.tar.gz")

    assert response(response, :not_found) == "Not found"
    assert get_resp_header(response, "cache-control") == ["no-store"]
  end

  test "viewer can inspect releases but cannot change the declassification policy", %{conn: conn} do
    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "release-viewer")

    assert {:ok, repository} =
             Repositories.register_github_repository(
               %{provider_id: 77_002, installation_id: 42, full_name: "private/read-only"},
               context
             )

    admin = Repo.one!(User)
    admin |> Ecto.Changeset.change(role: :viewer) |> Repo.update!()

    assert {:ok, releases, html} = live(conn, ~p"/repositories/#{repository.id}/releases")
    refute has_element?(releases, "#publication-policy-form")
    assert html =~ "Only an administrator can change"

    assert render_hook(releases, "save-policy", %{
             "policy" => %{"enabled" => "true", "public_slug" => "forged-public"}
           }) =~ "Only administrators can change publication policy."

    assert Repo.aggregate(PublicationPolicy, :count) == 0
  end

  defp signed_in_conn(conn) do
    post(conn, ~p"/setup", %{
      "token" => "test-bootstrap-token",
      "email" => "admin@example.com",
      "password" => "a secure password"
    })
  end

  defp insert_publication(repository_id, release, public_url, seconds, status \\ :published) do
    now =
      DateTime.utc_now()
      |> DateTime.add(seconds, :second)
      |> DateTime.truncate(:microsecond)

    attributes = %{
      id: Ecto.UUID.generate(),
      repository_id: repository_id,
      release: release,
      filename: "app.tar.gz",
      content_type: "application/gzip",
      digest: :crypto.hash(:sha256, release) |> Base.encode16(case: :lower),
      size: 1_024,
      status: status,
      source_commit: String.duplicate("c", 40),
      source_tag: release,
      public_url: public_url,
      published_at: now,
      withdrawn_at: if(status == :withdrawn, do: now),
      inserted_at: now,
      updated_at: now
    }

    Publication.changeset(%Publication{}, attributes) |> Repo.insert!()
  end
end
