defmodule RobineWeb.RunnerAttemptControllerTest do
  use RobineWeb.ConnCase, async: false
  use Oban.Testing, repo: Robine.Repo

  import Ecto.Query

  alias Robine.Adapters.Background.OutboxDeliveryWorker
  alias Robine.{Pipelines, Repo, Runners, Storage}
  alias Robine.Runtime.Dependencies

  test "serves only attempt-scoped transfers to the assigned runner", %{conn: conn} do
    admin_context =
      Dependencies.context(%{id: "admin-transfer", role: :administrator}, Ecto.UUID.generate())

    anonymous_context =
      Dependencies.context(%{id: "anonymous", role: :runner}, Ecto.UUID.generate())

    assert {:ok, enrollment} = Runners.create_enrollment_token(%{}, admin_context)

    assert {:ok, identity} =
             Runners.enroll(
               %{token: enrollment.token, name: "transfer-runner"},
               anonymous_context
             )

    runner_context =
      Dependencies.context(%{id: identity.runner_id, role: :runner}, Ecto.UUID.generate())

    assert {:ok, _welcome} =
             Runners.negotiate_protocol(
               %{
                 supported_protocol_versions: [1],
                 software_version: "0.2.0-dev",
                 capabilities: %{"docker" => true, "concurrency" => 1}
               },
               runner_context
             )

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Transfer",
                 commit_sha: String.duplicate("b", 40),
                 jobs: %{
                   "build" => %{
                     needs: [],
                     image: "alpine:3.22",
                     steps: [%{name: "Test", kind: :run, value: "true"}]
                   }
                 }
               },
               admin_context
             )

    outbox_job = Repo.one!(from job in Oban.Job, where: job.queue == "outbox")
    assert :ok = perform_job(OutboxDeliveryWorker, outbox_job.args)

    assert {:ok, attempt} =
             Pipelines.claim_next_job(%{runner_id: identity.runner_id}, admin_context)

    secrets =
      conn
      |> authenticate(identity)
      |> get(~p"/api/v1/runners/attempts/#{attempt.id}/secrets")

    assert json_response(secrets, :ok) == %{"secrets" => %{}}
    assert get_resp_header(secrets, "cache-control") == ["no-store"]

    source =
      build_conn()
      |> authenticate(identity)
      |> get(~p"/api/v1/runners/attempts/#{attempt.id}/source")

    assert json_response(source, :not_found) == %{"error" => "source not required"}

    cache_content = String.duplicate("cache-archive-", 12_000)

    saved_cache =
      build_conn()
      |> authenticate(identity)
      |> put_req_header("content-type", "application/octet-stream")
      |> put(~p"/api/v1/runners/attempts/#{attempt.id}/cache?key=mix-v1", cache_content)

    assert %{"digest" => cache_digest, "size" => size} =
             json_response(saved_cache, :created)

    assert size == byte_size(cache_content)

    restored_cache =
      build_conn()
      |> authenticate(identity)
      |> put_req_header("accept", "application/gzip")
      |> get(~p"/api/v1/runners/attempts/#{attempt.id}/cache?key=mix-v1")

    assert response(restored_cache, :ok) == cache_content
    assert get_resp_header(restored_cache, "x-content-sha256") == [cache_digest]
    assert get_resp_header(restored_cache, "cache-control") == ["no-store"]

    missing_cache =
      build_conn()
      |> authenticate(identity)
      |> get(~p"/api/v1/runners/attempts/#{attempt.id}/cache?key=missing")

    assert response(missing_cache, :no_content) == ""

    previous_transfer_limits = Application.fetch_env!(:robine, :transfer_limits)
    on_exit(fn -> Application.put_env(:robine, :transfer_limits, previous_transfer_limits) end)
    Application.put_env(:robine, :transfer_limits, max_archive_bytes: 4)

    oversized_artifact =
      build_conn()
      |> authenticate(identity)
      |> put_req_header("content-type", "application/octet-stream")
      |> put(
        ~p"/api/v1/runners/attempts/#{attempt.id}/artifacts?name=oversized&retention_days=7",
        "12345"
      )

    assert json_response(oversized_artifact, :request_entity_too_large) == %{
             "error" => "payload too large"
           }

    Application.put_env(:robine, :transfer_limits, previous_transfer_limits)

    artifact_content = "artifact-archive-#{Ecto.UUID.generate()}"

    uploaded_artifact =
      build_conn()
      |> authenticate(identity)
      |> put_req_header("content-type", "application/octet-stream")
      |> put(
        ~p"/api/v1/runners/attempts/#{attempt.id}/artifacts?name=reports&retention_days=7",
        artifact_content
      )

    assert %{"id" => artifact_id, "size" => artifact_size} =
             json_response(uploaded_artifact, :created)

    assert artifact_size == byte_size(artifact_content)

    assert {:ok, %{content: ^artifact_content}} =
             Storage.download_artifact(
               %{repository_id: pipeline.repository_id, artifact_id: artifact_id},
               admin_context
             )

    intruder = %{identity | runner_id: Ecto.UUID.generate()}

    denied =
      build_conn()
      |> authenticate(intruder)
      |> get(~p"/api/v1/runners/attempts/#{attempt.id}/secrets")

    assert json_response(denied, :unauthorized) == %{"error" => "unauthorized"}
    assert Repo.get!(Robine.Adapters.Persistence.Postgres.Schemas.Pipeline, pipeline.id)
  end

  defp authenticate(conn, identity) do
    conn
    |> put_req_header("authorization", "Bearer #{identity.credential}")
    |> put_req_header("x-robine-runner-id", identity.runner_id)
  end
end
