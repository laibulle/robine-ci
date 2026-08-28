defmodule RobineWeb.ManualArtifactControllerTest do
  use RobineWeb.ConnCase, async: false

  alias Robine.Adapters.Persistence.Postgres.Schemas.{Artifact, Session, User}
  alias Robine.Adapters.Storage.LocalBlobStore
  alias Robine.{Repo, Repositories}
  alias Robine.Runtime.Dependencies

  test "authenticates and streams an immutable manual artifact through the API", %{conn: conn} do
    conn = bootstrap(conn)
    repository = register_repository!()

    session_conn =
      conn
      |> recycle()
      |> post(~p"/api/v1/session", %{
        "email" => "admin@example.com",
        "password" => "a secure password"
      })

    assert %{
             "token" => token,
             "token_type" => "Bearer",
             "expires_at" => expires_at
           } = json_response(session_conn, 200)

    assert {:ok, _expires_at, 0} = DateTime.from_iso8601(expires_at)
    content = "signed-and-notarized-dmg"

    upload_conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/x-apple-diskimage")
      |> post(
        "/api/v1/repositories/#{repository.id}/artifacts?name=Robine.dmg&retention_days=30",
        content
      )

    assert %{
             "id" => artifact_id,
             "source" => "manual",
             "name" => "Robine.dmg",
             "content_type" => "application/x-apple-diskimage",
             "digest" => digest,
             "size" => size,
             "download_url" => download_url
           } = json_response(upload_conn, 201)

    assert size == byte_size(content)
    assert digest == :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    assert download_url == "/api/v1/repositories/#{repository.id}/artifacts/#{artifact_id}"

    persisted = Repo.get!(Artifact, artifact_id)
    assert persisted.attempt_id == nil
    assert persisted.source == :manual
    assert persisted.uploaded_by_id == Repo.one!(User).id

    list_conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/repositories/#{repository.id}/artifacts")

    assert %{"artifacts" => [%{"id" => ^artifact_id, "digest" => ^digest}]} =
             json_response(list_conn, 200)

    download_conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(download_url)

    assert response(download_conn, 200) == content

    assert get_resp_header(download_conn, "content-type") == [
             "application/x-apple-diskimage; charset=utf-8"
           ]

    assert get_resp_header(download_conn, "x-content-sha256") == [digest]
    assert get_resp_header(download_conn, "cache-control") == ["private, no-store"]

    assert :ok = LocalBlobStore.delete(digest)
  end

  test "rejects unauthorized, invalid, oversized, and quota-exceeding uploads", %{conn: conn} do
    conn = bootstrap(conn)
    repository = register_repository!()
    token = get_session(conn, :session_token)
    endpoint = "/api/v1/repositories/#{repository.id}/artifacts?name=Robine.dmg"

    anonymous =
      conn
      |> recycle()
      |> put_req_header("content-type", "application/octet-stream")
      |> post(endpoint, "bytes")

    assert %{"error" => "unauthorized"} = json_response(anonymous, 401)

    admin = Repo.one!(User)
    admin |> Ecto.Changeset.change(role: :viewer) |> Repo.update!()

    viewer =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(endpoint, "bytes")

    assert %{"error" => "forbidden"} = json_response(viewer, 403)
    assert Repo.aggregate(Artifact, :count) == 0

    admin = Repo.get!(User, admin.id)
    admin |> Ecto.Changeset.change(role: :administrator) |> Repo.update!()

    missing =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(
        "/api/v1/repositories/#{Ecto.UUID.generate()}/artifacts?name=missing.dmg",
        "bytes"
      )

    assert %{"error" => "not_found"} = json_response(missing, 404)

    previous_limit = Application.fetch_env!(:robine, :storage_max_object_bytes)
    Application.put_env(:robine, :storage_max_object_bytes, 4)
    on_exit(fn -> Application.put_env(:robine, :storage_max_object_bytes, previous_limit) end)

    oversized =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(endpoint, "12345")

    assert %{"error" => "payload_too_large"} = json_response(oversized, 413)
    assert Repo.aggregate(Artifact, :count) == 0

    Application.put_env(:robine, :storage_max_object_bytes, previous_limit)

    invalid_name =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(
        "/api/v1/repositories/#{repository.id}/artifacts?name=../Robine.dmg",
        "bytes"
      )

    assert %{"error" => "invalid_artifact", "field" => "name"} =
             json_response(invalid_name, 422)

    previous_quotas = Application.fetch_env!(:robine, :storage_quotas)
    Application.put_env(:robine, :storage_quotas, instance_bytes: 4, repository_bytes: 4)
    on_exit(fn -> Application.put_env(:robine, :storage_quotas, previous_quotas) end)

    quota_content = "12345"

    quota_exceeded =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(endpoint, quota_content)

    assert %{"error" => "quota_exceeded", "scope" => "instance", "limit" => 4} =
             json_response(quota_exceeded, 422)

    assert Repo.aggregate(Artifact, :count) == 0

    expired_at = DateTime.add(DateTime.utc_now(), -60, :second)

    Session
    |> Repo.one!()
    |> Ecto.Changeset.change(expires_at: expired_at)
    |> Repo.update!()

    expired =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(endpoint, "bytes")

    assert %{"error" => "unauthorized"} = json_response(expired, 401)
    assert Repo.aggregate(Artifact, :count) == 0

    quota_digest = :crypto.hash(:sha256, quota_content) |> Base.encode16(case: :lower)
    assert :ok = LocalBlobStore.delete(quota_digest)
  end

  defp bootstrap(conn) do
    post(conn, ~p"/setup", %{
      "token" => "test-bootstrap-token",
      "email" => "admin@example.com",
      "password" => "a secure password"
    })
  end

  defp register_repository! do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "manual-api")
    provider_id = System.unique_integer([:positive])

    assert {:ok, repository} =
             Repositories.register_github_repository(
               %{
                 provider_id: provider_id,
                 installation_id: provider_id,
                 full_name: "acme/manual-api-#{provider_id}"
               },
               context
             )

    repository
  end
end
