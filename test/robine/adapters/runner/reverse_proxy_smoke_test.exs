defmodule Robine.Adapters.Runner.ReverseProxySmokeTest do
  use Robine.DataCase, async: false
  use Oban.Testing, repo: Robine.Repo

  import Ecto.Query

  alias Robine.Adapters.Background.{OutboxDeliveryWorker, RunNextJobWorker}
  alias Robine.Adapters.Persistence.Postgres.Schemas.{Artifact, Attempt, CacheEntry, Pipeline}
  alias Robine.Adapters.Runner.{RemoteClient, RemoteExecutor}
  alias Robine.Adapters.Storage.{ExAwsS3Client, S3BlobStore}
  alias Robine.Runtime.Dependencies
  alias Robine.TestSupport.{CaddyProxy, MinioServer, RestartableEndpoint}
  alias Robine.{Pipelines, Repo, Runners}

  @moduletag :docker
  @caddy_executable System.find_executable("caddy")

  if is_nil(@caddy_executable) do
    @moduletag skip: "Caddy is required for the reverse-proxy smoke test"
  end

  setup do
    {:ok, caddy: @caddy_executable}
  end

  test "an outbound-only runner survives a control-plane restart behind a real reverse proxy", %{
    caddy: caddy
  } do
    endpoint = start_supervised!(RestartableEndpoint)
    backend_port = RestartableEndpoint.port(endpoint)

    proxy =
      start_supervised!({CaddyProxy, executable: caddy, backend_port: backend_port})

    proxy_url = CaddyProxy.url(proxy)
    previous_public_url = Application.fetch_env!(:robine, :public_url)
    Application.put_env(:robine, :public_url, proxy_url)

    on_exit(fn -> Application.put_env(:robine, :public_url, previous_public_url) end)

    {identity, admin_context} = enroll_runner()

    client =
      start_supervised!(
        {RemoteClient,
         server_url: proxy_url,
         runner_id: identity.runner_id,
         credential: identity.credential,
         owner: self(),
         software_version: "0.2.0-proxy-smoke",
         capabilities: %{
           "os" => "linux",
           "architecture" => "amd64",
           "docker" => true,
           "concurrency" => 1
         }}
      )

    assert_receive {:runner_connection, :connected}, 5_000
    assert_receive {:runner_connection, :ready, welcome}, 5_000
    assert welcome["protocol_version"] == 1

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Reverse proxy smoke",
                 commit_sha: String.duplicate("e", 40),
                 jobs: %{
                   "build" => %{
                     needs: [],
                     image: "postgres:18-alpine",
                     runs_on: ["docker"],
                     services: %{
                       "postgres" => %{
                         id: "postgres",
                         image: "postgres:18-alpine",
                         user: "postgres",
                         env: %{
                           "POSTGRES_USER" => "robine",
                           "POSTGRES_DB" => "proxy_test",
                           "POSTGRES_HOST_AUTH_METHOD" => "trust"
                         },
                         readiness: %{tcp: 5432, timeout_ms: 30_000}
                       }
                     },
                     steps: [
                       %{
                         name: "Prove proxied execution",
                         kind: :run,
                         value:
                           "pg_isready -h postgres; psql -h postgres -U robine -d proxy_test -Atc 'select 42'; printf 'container-started'; sleep 2; printf 'runner-through-caddy-after-restart'"
                       }
                     ]
                   }
                 }
               },
               admin_context
             )

    outbox_job = Repo.one!(from job in Oban.Job, where: job.queue == "outbox")
    assert :ok = perform_job(OutboxDeliveryWorker, outbox_job.args)
    assert :ok = perform_job(RunNextJobWorker, %{})

    assert_receive {:runner_message, "job_offer", offer}, 5_000
    assert URI.parse(offer["secrets_url"]).port == URI.parse(proxy_url).port

    owner = self()

    executor =
      spawn_link(fn ->
        result =
          RemoteExecutor.run(offer, client, %{
            "runner_id" => identity.runner_id,
            "credential" => identity.credential
          })

        send(owner, {:remote_execution_complete, result})
      end)

    assert_attempt_acknowledgement(offer["attempt_id"], 2)
    assert_log_acknowledgement()
    assert :ok = RestartableEndpoint.restart(endpoint)
    assert_receive {:runner_connection, :disconnected, _reason, _delay}, 5_000
    assert_receive {:runner_connection, :connected}, 5_000
    assert_receive {:runner_connection, :ready, resumed}, 5_000

    assert resumed["resume"] == [
             %{"attempt_id" => offer["attempt_id"], "acknowledged_sequence" => 2}
           ]

    assert_receive {:remote_execution_complete, execution_result}, 30_000
    assert_attempt_acknowledgement(offer["attempt_id"], 3)

    unless execution_result == :ok do
      attempt = Repo.get!(Attempt, offer["attempt_id"])
      assert {:ok, logs} = Pipelines.list_job_logs(%{job_id: attempt.job_id}, admin_context)

      flunk(
        "remote service execution failed: #{inspect(execution_result)} #{inspect(logs.chunks)}"
      )
    end

    refute Process.alive?(executor)

    attempt = Repo.get!(Attempt, offer["attempt_id"])
    assert attempt.status == :succeeded
    assert Repo.get!(Pipeline, pipeline.id).status == :succeeded

    assert Repo.aggregate(
             from(stored in Attempt, where: stored.job_id == ^attempt.job_id),
             :count
           ) == 1
  end

  test "version skew is actionable and revocation is immediate through the proxy", %{caddy: caddy} do
    endpoint = start_supervised!(RestartableEndpoint)

    proxy =
      start_supervised!(
        {CaddyProxy, executable: caddy, backend_port: RestartableEndpoint.port(endpoint)}
      )

    proxy_url = CaddyProxy.url(proxy)
    {incompatible_identity, _admin_context} = enroll_runner()

    start_supervised!(
      {RemoteClient,
       server_url: proxy_url,
       runner_id: incompatible_identity.runner_id,
       credential: incompatible_identity.credential,
       owner: self(),
       supported_protocol_versions: [99],
       software_version: "99.0.0"},
      id: :incompatible_remote_client
    )

    assert_receive {:runner_connection, :connected}, 5_000

    assert_receive {:runner_reply, "1",
                    %{
                      "status" => "error",
                      "response" => %{
                        "code" => "incompatible_protocol",
                        "supported_protocol_versions" => [1]
                      }
                    }},
                   5_000

    stop_supervised!(:incompatible_remote_client)

    {identity, admin_context} = enroll_runner()

    start_supervised!(
      {RemoteClient,
       server_url: proxy_url,
       runner_id: identity.runner_id,
       credential: identity.credential,
       owner: self()},
      id: :revoked_remote_client
    )

    assert_receive {:runner_connection, :connected}, 5_000
    assert_receive {:runner_connection, :ready, _welcome}, 5_000
    assert :ok = Runners.revoke(%{runner_id: identity.runner_id}, admin_context)

    assert_receive {:runner_message, "runner_revoked", %{"cancel_active_attempts" => true}},
                   5_000
  end

  @minio_image_available match?(
                           {_output, 0},
                           System.cmd(
                             "docker",
                             ["image", "inspect", MinioServer.image()],
                             stderr_to_stdout: true
                           )
                         )

  @tag :s3_journey
  if not @minio_image_available do
    @tag skip: "the pinned MinIO integration image is not installed"
  end

  test "remote jobs publish and restore S3-backed caches and artifacts without bucket credentials",
       %{
         caddy: caddy
       } do
    endpoint = start_supervised!(RestartableEndpoint)

    proxy =
      start_supervised!(
        {CaddyProxy, executable: caddy, backend_port: RestartableEndpoint.port(endpoint)}
      )

    minio = start_supervised!(MinioServer)
    s3 = configure_s3!(MinioServer.endpoint(minio))
    proxy_url = CaddyProxy.url(proxy)
    previous_public_url = Application.fetch_env!(:robine, :public_url)
    previous_adapter = Application.fetch_env!(:robine, :blob_store_adapter)
    previous_s3 = Application.get_env(:robine, :s3_blob_store)

    Application.put_env(:robine, :public_url, proxy_url)
    Application.put_env(:robine, :blob_store_adapter, S3BlobStore)
    Application.put_env(:robine, :s3_blob_store, s3)

    on_exit(fn ->
      Application.put_env(:robine, :public_url, previous_public_url)
      Application.put_env(:robine, :blob_store_adapter, previous_adapter)

      if previous_s3,
        do: Application.put_env(:robine, :s3_blob_store, previous_s3),
        else: Application.delete_env(:robine, :s3_blob_store)

      File.rm_rf(Keyword.fetch!(s3, :spool_root))
    end)

    {identity, admin_context} = enroll_runner()

    client =
      start_supervised!(
        {RemoteClient,
         server_url: proxy_url,
         runner_id: identity.runner_id,
         credential: identity.credential,
         owner: self(),
         capabilities: %{
           "os" => "linux",
           "architecture" => "amd64",
           "docker" => true,
           "concurrency" => 1
         }}
      )

    assert_receive {:runner_connection, :connected}, 5_000
    assert_receive {:runner_connection, :ready, _welcome}, 5_000
    repository_id = Ecto.UUID.generate()

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: repository_id,
                 workflow_name: "Remote S3 journey",
                 commit_sha: String.duplicate("f", 40),
                 jobs: %{
                   "build" => %{
                     needs: [],
                     image:
                       "redis@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241",
                     runs_on: ["docker"],
                     services: %{
                       "redis" => %{
                         id: "redis",
                         image:
                           "redis@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241",
                         user: "redis",
                         readiness: %{tcp: 6379, timeout_ms: 15_000}
                       }
                     },
                     steps: [
                       %{
                         name: "Create retained content",
                         kind: :run,
                         value:
                           "test \"$(redis-cli -h redis ping)\" = PONG; mkdir -p deps reports; printf cache-s3 > deps/value; printf artifact-s3 > reports/value"
                       },
                       %{
                         name: "Save cache",
                         kind: :builtin,
                         value: "cache/save",
                         with: %{"key" => "deps-s3-v1", "paths" => ["deps"]}
                       },
                       %{
                         name: "Upload artifact",
                         kind: :builtin,
                         value: "artifacts/upload",
                         with: %{
                           "name" => "reports",
                           "paths" => ["reports"],
                           "retention-days" => 7
                         }
                       }
                     ]
                   },
                   "consume" => %{
                     needs: ["build"],
                     image: "alpine:3.22",
                     runs_on: ["docker"],
                     steps: [
                       %{
                         name: "Restore cache",
                         kind: :builtin,
                         value: "cache/restore",
                         with: %{"key" => "deps-s3-v1", "paths" => ["deps"]}
                       },
                       %{
                         name: "Download artifact",
                         kind: :builtin,
                         value: "artifacts/download",
                         with: %{"name" => "reports", "from" => "build", "path" => "."}
                       },
                       %{
                         name: "Verify restored content",
                         kind: :run,
                         value:
                           "test \"$(cat deps/value)\" = cache-s3 && test \"$(cat reports/value)\" = artifact-s3"
                       }
                     ]
                   }
                 }
               },
               admin_context
             )

    outbox_job = Repo.one!(from job in Oban.Job, where: job.queue == "outbox")
    assert :ok = perform_job(OutboxDeliveryWorker, outbox_job.args)
    assert :ok = perform_job(RunNextJobWorker, %{})

    first_offer = receive_offer_without_s3_credentials()
    assert first_offer["execution"]["needs"] == []
    assert :ok = RemoteExecutor.run(first_offer, client, runner_config(identity))
    assert_attempt_acknowledgement(first_offer["attempt_id"], 3)
    assert Repo.get!(Attempt, first_offer["attempt_id"]).status == :succeeded

    assert {:ok, %{content: cache_archive}} =
             Robine.Storage.restore_cache(
               %{repository_id: repository_id, key: "deps-s3-v1"},
               admin_context
             )

    assert is_binary(cache_archive)
    assert :ok = perform_job(RunNextJobWorker, %{})

    second_offer = receive_offer_without_s3_credentials()
    assert second_offer["execution"]["needs"] == ["build"]

    assert {:ok, %{status: 200, body: transfer_probe}} =
             Req.get(second_offer["builtins_url"] <> "/cache?key=deps-s3-v1",
               headers: [
                 {"authorization", "Bearer #{identity.credential}"},
                 {"x-robine-runner-id", identity.runner_id}
               ],
               decode_body: false,
               retry: false
             )

    assert transfer_probe == cache_archive
    assert :ok = RemoteExecutor.run(second_offer, client, runner_config(identity))
    assert_attempt_acknowledgement(second_offer["attempt_id"], 3)
    second_attempt = Repo.get!(Attempt, second_offer["attempt_id"])

    assert {:ok, second_logs} =
             Pipelines.list_job_logs(%{job_id: second_attempt.job_id}, admin_context)

    assert second_attempt.status == :succeeded,
           "consumer failed with #{inspect(second_attempt.result_reason)}: #{inspect(second_logs.chunks)}"

    assert Repo.get!(Pipeline, pipeline.id).status == :succeeded

    assert Repo.aggregate(
             from(entry in CacheEntry, where: entry.repository_id == ^repository_id),
             :count
           ) == 1

    assert Repo.aggregate(
             from(artifact in Artifact, where: artifact.repository_id == ^repository_id),
             :count
           ) == 1

    assert {:ok, %{objects: objects, unsafe: 0}} = S3BlobStore.inventory()
    assert length(objects) == 2
  end

  defp enroll_runner do
    admin_context =
      Dependencies.context(%{id: "admin-proxy-smoke", role: :administrator}, Ecto.UUID.generate())

    runner_context =
      Dependencies.context(%{id: "anonymous", role: :runner}, Ecto.UUID.generate())

    assert {:ok, enrollment} = Runners.create_enrollment_token(%{}, admin_context)

    assert {:ok, identity} =
             Runners.enroll(
               %{token: enrollment.token, name: "proxy-smoke", labels: ["docker"]},
               runner_context
             )

    {identity, admin_context}
  end

  defp assert_attempt_acknowledgement(attempt_id, sequence) do
    receive do
      {:runner_reply, _reference,
       %{
         "status" => "ok",
         "response" => %{
           "attempt_id" => ^attempt_id,
           "acknowledged_sequence" => ^sequence
         }
       }} ->
        :ok
    after
      5_000 ->
        flunk("the control plane did not durably acknowledge runner sequence #{sequence}")
    end
  end

  defp assert_log_acknowledgement do
    receive do
      {:runner_reply, _reference, %{"status" => "ok", "response" => %{"sequence" => sequence}}}
      when is_integer(sequence) ->
        :ok
    after
      10_000 -> flunk("the running container did not stream a log before control-plane restart")
    end
  end

  defp receive_offer_without_s3_credentials do
    assert_receive {:runner_message, "job_offer", offer}, 5_000
    serialized = Jason.encode!(offer)
    refute serialized =~ "robine-test-access"
    refute serialized =~ "robine-test-secret-key"
    refute serialized =~ "ROBINE_S3"
    offer
  end

  defp runner_config(identity) do
    %{"runner_id" => identity.runner_id, "credential" => identity.credential}
  end

  defp configure_s3!(endpoint) do
    spool_root = Path.join(System.tmp_dir!(), "robine-runner-s3-#{Ecto.UUID.generate()}")

    config = [
      client: ExAwsS3Client,
      endpoint: endpoint,
      region: "us-east-1",
      bucket: "robine-runner-journey",
      prefix: "control-plane",
      allow_http_loopback: true,
      path_style: true,
      access_key_id: "robine-test-access",
      secret_access_key: "robine-test-secret-key",
      spool_root: spool_root,
      part_size: 5 * 1024 * 1024,
      multipart_concurrency: 2,
      part_timeout_ms: 30_000
    ]

    assert {:ok, _response} =
             ExAws.S3.put_bucket(Keyword.fetch!(config, :bucket), "us-east-1")
             |> ExAws.request(s3_request_config(config))

    config
  end

  defp s3_request_config(config) do
    endpoint = URI.parse(Keyword.fetch!(config, :endpoint))

    [
      region: Keyword.fetch!(config, :region),
      scheme: endpoint.scheme <> "://",
      host: endpoint.host,
      port: endpoint.port,
      virtual_host: false,
      access_key_id: Keyword.fetch!(config, :access_key_id),
      secret_access_key: Keyword.fetch!(config, :secret_access_key)
    ]
  end
end
