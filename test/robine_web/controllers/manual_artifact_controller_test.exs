defmodule RobineWeb.ManualArtifactControllerTest do
  use RobineWeb.ConnCase, async: false

  alias Robine.Adapters.Persistence.Postgres.Schemas.{ApiToken, Artifact, Session, User}
  alias Robine.Adapters.Storage.LocalBlobStore
  alias Robine.{Identities, Repo, Repositories}
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

  test "uses a global artifacts:write token to upload to every trusted repository", %{conn: conn} do
    conn = bootstrap(conn)
    repository = register_repository!()
    other_repository = register_repository!()
    user = Repo.one!(User)
    context = Dependencies.context(%{id: user.id, role: :administrator}, "api-token-test")

    assert {:ok, %{token: token, credential: credential}} =
             Identities.create_api_token(
               %{
                 name: "DMG upload",
                 permissions: ["artifacts:write"],
                 expires_in_days: 30
               },
               context
             )

    assert String.starts_with?(token, "rbn_art_")
    assert credential.permissions == ["artifacts:write"]

    persisted = Repo.get!(ApiToken, credential.id)
    assert persisted.token_digest == :crypto.hash(:sha256, token)
    refute inspect(persisted) =~ token

    content = "signed-token-upload"

    upload =
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
             "uploaded_by_id" => uploaded_by_id,
             "digest" => digest
           } =
             json_response(upload, 201)

    assert uploaded_by_id == user.id
    assert Repo.get!(ApiToken, credential.id).last_used_at

    list_attempt =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/repositories/#{repository.id}/artifacts")

    assert %{"error" => "forbidden"} = json_response(list_attempt, 403)

    download_attempt =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/repositories/#{repository.id}/artifacts/#{artifact_id}")

    assert %{"error" => "forbidden"} = json_response(download_attempt, 403)

    other_upload =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(
        "/api/v1/repositories/#{other_repository.id}/artifacts?name=wrong.dmg",
        "second-upload"
      )

    assert %{"digest" => second_digest} = json_response(other_upload, 201)
    assert Repo.aggregate(Artifact, :count) == 2

    missing_repository =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(
        "/api/v1/repositories/#{Ecto.UUID.generate()}/artifacts?name=missing.dmg",
        "not-stored"
      )

    assert %{"error" => "not_found"} = json_response(missing_repository, 404)
    assert Repo.aggregate(Artifact, :count) == 2

    assert :ok =
             Identities.revoke_api_token(
               %{token_id: credential.id},
               context
             )

    revoked =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/api/v1/repositories/#{repository.id}/artifacts?name=revoked.dmg", "bytes")

    assert %{"error" => "unauthorized"} = json_response(revoked, 401)
    assert Repo.aggregate(Artifact, :count) == 2
    assert :ok = LocalBlobStore.delete(digest)
    assert :ok = LocalBlobStore.delete(second_digest)
  end

  test "rejects expired, malformed, unknown, disabled-owner, and non-admin token management", %{
    conn: conn
  } do
    conn = bootstrap(conn)
    repository = register_repository!()
    user = Repo.one!(User)
    context = Dependencies.context(%{id: user.id, role: :administrator}, "invalid-api-token")

    assert {:ok, %{token: expired_token, credential: expired_credential}} =
             Identities.create_api_token(
               %{
                 name: "Expiring token",
                 permissions: ["artifacts:write"],
                 expires_in_days: 1
               },
               context
             )

    expired_credential.id
    |> then(&Repo.get!(ApiToken, &1))
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
    |> Repo.update!()

    assert_unauthorized_token(conn, repository.id, expired_token)
    assert_unauthorized_token(conn, repository.id, "rbn_art_malformed")

    unknown = "rbn_art_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
    assert_unauthorized_token(conn, repository.id, unknown)

    assert {:ok, %{token: disabled_token}} =
             Identities.create_api_token(
               %{
                 name: "Disabled owner",
                 permissions: ["artifacts:write"],
                 expires_in_days: 30
               },
               context
             )

    user |> Ecto.Changeset.change(disabled: true) |> Repo.update!()
    assert_unauthorized_token(conn, repository.id, disabled_token)
    assert Repo.aggregate(Artifact, :count) == 0

    user =
      user.id
      |> then(&Repo.get!(User, &1))
      |> Ecto.Changeset.change(disabled: false)
      |> Repo.update!()

    assert {:ok, %{token: demoted_owner_token}} =
             Identities.create_api_token(
               %{
                 name: "Demoted owner",
                 permissions: ["artifacts:write"],
                 expires_in_days: 30
               },
               context
             )

    user |> Ecto.Changeset.change(role: :maintainer) |> Repo.update!()
    assert_unauthorized_token(conn, repository.id, demoted_owner_token)
    assert Repo.aggregate(Artifact, :count) == 0

    for role <- [:maintainer, :viewer] do
      unauthorized = %{context | actor: %{id: user.id, role: role}}

      assert {:error, :forbidden} =
               Identities.create_api_token(
                 %{
                   name: "Forged #{role} token",
                   permissions: ["artifacts:write"],
                   expires_in_days: 30
                 },
                 unauthorized
               )

      assert {:error, :forbidden} = Identities.list_api_tokens(%{}, unauthorized)

      assert {:error, :forbidden} =
               Identities.revoke_api_token(
                 %{token_id: expired_credential.id},
                 unauthorized
               )
    end
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

  defp assert_unauthorized_token(conn, repository_id, token) do
    response =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/api/v1/repositories/#{repository_id}/artifacts?name=rejected.dmg", "bytes")

    assert %{"error" => "unauthorized"} = json_response(response, 401)
  end
end
