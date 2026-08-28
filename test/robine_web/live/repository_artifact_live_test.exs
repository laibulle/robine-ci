defmodule RobineWeb.RepositoryArtifactLiveTest do
  use RobineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Robine.Adapters.Persistence.Postgres.Schemas.{Artifact, User}
  alias Robine.Adapters.Storage.LocalBlobStore
  alias Robine.{Repo, Repositories, Storage}
  alias Robine.Runtime.Dependencies

  test "uploads, lists, and downloads a locally produced artifact", %{conn: conn} do
    conn = bootstrap(conn)
    repository = register_repository!()

    assert {:ok, view, _html} = live(conn, ~p"/repositories/#{repository.id}/artifacts")
    assert has_element?(view, "#manual-artifact-upload-panel")
    assert has_element?(view, "#repository-artifacts-empty")

    content = "notarized-dmg-content"

    upload =
      file_input(view, "#manual-artifact-form", :artifact, [
        %{
          name: "Robine.dmg",
          content: content,
          type: "application/x-apple-diskimage"
        }
      ])

    assert render_upload(upload, "Robine.dmg") =~ "100%"

    view
    |> form("#manual-artifact-form", artifact_upload: %{retention_days: "30"})
    |> render_submit()

    artifact = Repo.one!(Artifact)
    assert artifact.source == :manual
    assert artifact.attempt_id == nil
    assert artifact.digest == :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    assert has_element?(view, "#artifacts-#{artifact.id}")
    assert has_element?(view, "#last-manual-upload", artifact.digest)
    assert has_element?(view, "#artifact-count", "1 artifact")

    download =
      conn
      |> recycle()
      |> get(~p"/repositories/#{repository.id}/artifacts/#{artifact.id}/download")

    assert response(download, 200) == content
    assert get_resp_header(download, "x-content-sha256") == [artifact.digest]
    assert get_resp_header(download, "cache-control") == ["private, no-store"]

    assert :ok = LocalBlobStore.delete(artifact.digest)
  end

  test "lists and downloads an artifact produced by a CI attempt", %{conn: conn} do
    conn = bootstrap(conn)
    repository = register_repository!()
    user = Repo.one!(User)
    context = Dependencies.context(%{id: user.id, role: :administrator}, "ci-artifact-live")
    content = "tag-release-archive"

    assert {:ok, artifact} =
             Storage.upload_artifact(
               %{
                 repository_id: repository.id,
                 attempt_id: Ecto.UUID.generate(),
                 name: "github-release-robine-server-linux-amd64",
                 content: content,
                 retention_seconds: 86_400
               },
               context
             )

    assert {:ok, view, _html} = live(conn, ~p"/repositories/#{repository.id}/artifacts")
    assert has_element?(view, "#artifacts-#{artifact.id}", artifact.name)
    assert has_element?(view, "#artifacts-#{artifact.id} .badge", "CI")
    assert has_element?(view, "#download-artifact-#{artifact.id}")
    assert has_element?(view, "#artifact-count", "1 artifact")

    download =
      conn
      |> recycle()
      |> get(~p"/repositories/#{repository.id}/artifacts/#{artifact.id}/download")

    assert response(download, 200) == content
    assert get_resp_header(download, "x-content-sha256") == [artifact.digest]
    assert :ok = LocalBlobStore.delete(artifact.digest)
  end

  test "keeps upload controls unavailable to viewers", %{conn: conn} do
    conn = bootstrap(conn)
    repository = register_repository!()

    user = Repo.one!(User)
    user |> Ecto.Changeset.change(role: :viewer) |> Repo.update!()

    assert {:ok, view, _html} = live(conn, ~p"/repositories/#{repository.id}/artifacts")
    refute has_element?(view, "#manual-artifact-upload-panel")
    refute has_element?(view, "#upload-manual-artifact")
  end

  defp bootstrap(conn) do
    post(conn, ~p"/setup", %{
      "token" => "test-bootstrap-token",
      "email" => "admin@example.com",
      "password" => "a secure password"
    })
  end

  defp register_repository! do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "manual-live")
    provider_id = System.unique_integer([:positive])

    assert {:ok, repository} =
             Repositories.register_github_repository(
               %{
                 provider_id: provider_id,
                 installation_id: provider_id,
                 full_name: "acme/manual-live-#{provider_id}"
               },
               context
             )

    repository
  end
end
