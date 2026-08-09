defmodule RobineWeb.RunnerChannelTest do
  use Robine.DataCase, async: false
  use Oban.Testing, repo: Robine.Repo

  import Ecto.Query
  import Phoenix.ChannelTest

  alias Robine.Adapters.Background.{OutboxDeliveryWorker, RunNextJobWorker}
  alias Robine.Adapters.Persistence.Postgres.Schemas.RemoteRunner
  alias Robine.{Pipelines, Repo, Runners}
  alias Robine.Runtime.Dependencies

  @endpoint RobineWeb.Endpoint

  test "authenticates through upgrade headers, negotiates v1, and heartbeats" do
    {identity, admin_context} = enroll_runner()

    assert {:ok, socket} = connect_runner(identity)

    hello = %{
      "supported_protocol_versions" => [1],
      "software_version" => "0.2.0-dev",
      "capabilities" => %{"os" => "linux", "docker" => true, "concurrency" => 1}
    }

    assert {:ok, welcome, socket} =
             subscribe_and_join(socket, RobineWeb.RunnerChannel, "runner:v1", hello)

    assert welcome.protocol_version == 1
    assert welcome.heartbeat_interval_seconds == 20
    assert welcome.stale_after_seconds == 60

    stored = Repo.get!(RemoteRunner, identity.runner_id)
    assert stored.protocol_version == 1
    assert stored.software_version == "0.2.0-dev"
    assert stored.capabilities == %{"os" => "linux", "docker" => true, "concurrency" => 1}
    assert stored.last_seen_at

    reference = push(socket, "heartbeat", %{})
    assert_reply reference, :ok, %{server_time: _server_time}

    assert :ok = Runners.revoke(%{runner_id: identity.runner_id}, admin_context)
    assert_push "runner_revoked", %{"cancel_active_attempts" => true}
    reference = push(socket, "heartbeat", %{})
    assert_reply reference, :error, %{code: "unauthorized"}
  end

  test "rejects missing credentials and incompatible protocol versions" do
    {identity, _admin_context} = enroll_runner()

    assert :error =
             connect(RobineWeb.RunnerSocket, %{},
               connect_info: %{x_headers: [{"x-robine-runner-id", identity.runner_id}]}
             )

    assert {:ok, socket} = connect_runner(identity)

    assert {:error, %{code: "incompatible_protocol", supported_protocol_versions: [1]}} =
             subscribe_and_join(socket, RobineWeb.RunnerChannel, "runner:v1", %{
               "supported_protocol_versions" => [99],
               "software_version" => "99.0.0",
               "capabilities" => %{}
             })
  end

  test "acknowledges durable attempt events and duplicate delivery" do
    {identity, admin_context} = enroll_runner()

    assert {:ok, socket} = connect_runner(identity)

    assert {:ok, welcome, socket} =
             subscribe_and_join(socket, RobineWeb.RunnerChannel, "runner:v1", %{
               "supported_protocol_versions" => [1],
               "software_version" => "0.2.0-dev",
               "capabilities" => %{"docker" => true},
               "active_attempt_ids" => []
             })

    assert welcome.resume == []

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Remote",
                 commit_sha: String.duplicate("a", 40),
                 jobs: %{"build" => %{needs: []}}
               },
               admin_context
             )

    outbox_job = Repo.one!(from job in Oban.Job, where: job.queue == "outbox")
    assert :ok = perform_job(OutboxDeliveryWorker, outbox_job.args)

    assert {:ok, attempt} =
             Pipelines.claim_next_job(%{runner_id: identity.runner_id}, admin_context)

    message_id = Ecto.UUID.generate()

    message = %{
      "idempotency_token" => attempt.idempotency_token,
      "message_id" => message_id,
      "sequence" => 1,
      "status" => "preparing"
    }

    reference = push(socket, "attempt_event", message)

    assert_reply reference, :ok, %{message_id: ^message_id, acknowledged_sequence: 1}

    skipped_log =
      push(socket, "log_event", %{
        "attempt_id" => attempt.id,
        "sequence" => 1_000_001,
        "phase" => "execution",
        "stream" => "system",
        "step_position" => 1,
        "step_name" => "Success only",
        "status" => "skipped",
        "exit_code" => nil,
        "duration_ms" => 0,
        "content" => "Skipped because if: success did not match failure"
      })

    assert_reply skipped_log, :ok, %{sequence: 1_000_001}

    assert Repo.one!(
             from chunk in Robine.Adapters.Persistence.Postgres.Schemas.LogChunk,
               where: chunk.attempt_id == ^attempt.id
           ).step_status == "skipped"

    duplicate = push(socket, "attempt_event", message)
    assert_reply duplicate, :ok, %{acknowledged_sequence: 1}

    gap =
      push(socket, "attempt_event", %{
        message
        | "message_id" => Ecto.UUID.generate(),
          "sequence" => 3,
          "status" => "running"
      })

    assert_reply gap, :error, %{code: "event_gap", expected_sequence: 2, received_sequence: 3}

    assert Repo.get!(Robine.Adapters.Persistence.Postgres.Schemas.Pipeline, pipeline.id).status ==
             :running

    assert {:ok, %{status: :cancelling}} =
             Pipelines.cancel_pipeline(%{pipeline_id: pipeline.id}, admin_context)

    heartbeat = push(socket, "heartbeat", %{})

    assert_reply heartbeat, :ok, %{
      cancellation_requested_attempt_ids: [attempt_id],
      renewed_attempts: 1
    }

    assert attempt_id == attempt.id
  end

  test "dispatch worker offers a normalized job to an online runner" do
    {identity, admin_context} = enroll_runner()
    assert {:ok, socket} = connect_runner(identity)

    assert {:ok, _welcome, socket} =
             subscribe_and_join(socket, RobineWeb.RunnerChannel, "runner:v1", %{
               "supported_protocol_versions" => [1],
               "software_version" => "0.2.0-dev",
               "capabilities" => %{"docker" => true, "concurrency" => 1},
               "active_attempt_ids" => []
             })

    assert {:ok, _pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Remote offer",
                 commit_sha: String.duplicate("c", 40),
                 jobs: %{
                   "build[version=3.22]" => %{
                     base_id: "build",
                     matrix_values: %{"version" => "3.22"},
                     needs: [],
                     image: "alpine:3.22",
                     env: %{"ROBINE_MATRIX_VERSION" => "3.22"},
                     steps: [%{name: "Hello", kind: :run, value: "echo hello"}]
                   }
                 }
               },
               admin_context
             )

    outbox_job = Repo.one!(from job in Oban.Job, where: job.queue == "outbox")
    assert :ok = perform_job(OutboxDeliveryWorker, outbox_job.args)
    assert :ok = perform_job(RunNextJobWorker, %{})

    assert_push "job_offer", offer
    assert is_binary(offer["attempt_id"])
    assert is_binary(offer["idempotency_token"])
    assert offer["execution"]["image"] == "alpine:3.22"
    assert offer["execution"]["base_id"] == "build"
    assert offer["execution"]["matrix_values"] == %{"version" => "3.22"}
    assert offer["execution"]["env"]["ROBINE_MATRIX_VERSION"] == "3.22"
    assert offer["source_url"] == nil
    assert String.ends_with?(offer["secrets_url"], "/secrets")
    assert String.ends_with?(offer["builtins_url"], "/#{offer["attempt_id"]}")

    acceptance =
      push(socket, "job_accept", %{
        "attempt_id" => offer["attempt_id"],
        "idempotency_token" => offer["idempotency_token"],
        "message_id" => Ecto.UUID.generate()
      })

    assert_reply acceptance, :ok, %{attempt_id: accepted_attempt_id, acknowledged_sequence: 1}
    assert accepted_attempt_id == offer["attempt_id"]

    attempt =
      Repo.get!(Robine.Adapters.Persistence.Postgres.Schemas.Attempt, offer["attempt_id"])

    assert attempt.runner_id == identity.runner_id
    assert attempt.status == :preparing
  end

  test "a fresh channel process resumes durable work without creating a second attempt" do
    {identity, admin_context} = enroll_runner()

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Reconnect",
                 commit_sha: String.duplicate("d", 40),
                 jobs: %{"build" => %{needs: []}}
               },
               admin_context
             )

    outbox_job = Repo.one!(from job in Oban.Job, where: job.queue == "outbox")
    assert :ok = perform_job(OutboxDeliveryWorker, outbox_job.args)

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

    assert {:ok, attempt} =
             Pipelines.claim_next_job(%{runner_id: identity.runner_id}, admin_context)

    assert {:ok, socket} = connect_runner(identity)

    assert {:ok, _welcome, socket} =
             subscribe_and_join(socket, RobineWeb.RunnerChannel, "runner:v1", %{
               "supported_protocol_versions" => [1],
               "software_version" => "0.2.0-dev",
               "capabilities" => %{"docker" => true, "concurrency" => 1},
               "active_attempt_ids" => []
             })

    accept =
      push(socket, "job_accept", %{
        "attempt_id" => attempt.id,
        "idempotency_token" => attempt.idempotency_token,
        "message_id" => Ecto.UUID.generate()
      })

    assert_reply accept, :ok, %{acknowledged_sequence: 1}

    running =
      push(socket, "attempt_event", %{
        "idempotency_token" => attempt.idempotency_token,
        "message_id" => Ecto.UUID.generate(),
        "sequence" => 2,
        "status" => "running"
      })

    assert_reply running, :ok, %{acknowledged_sequence: 2}

    Process.unlink(socket.channel_pid)
    assert :ok = close(socket)

    assert {:ok, replacement} = connect_runner(identity)

    assert {:ok, welcome, _replacement} =
             subscribe_and_join(replacement, RobineWeb.RunnerChannel, "runner:v1", %{
               "supported_protocol_versions" => [1],
               "software_version" => "0.2.0-dev",
               "capabilities" => %{"docker" => true, "concurrency" => 1},
               "active_attempt_ids" => [attempt.id]
             })

    assert welcome.resume == [%{attempt_id: attempt.id, acknowledged_sequence: 2}]

    assert Repo.aggregate(
             from(stored in Robine.Adapters.Persistence.Postgres.Schemas.Attempt,
               where: stored.job_id == ^attempt.job_id
             ),
             :count
           ) == 1

    assert Repo.get!(Robine.Adapters.Persistence.Postgres.Schemas.Pipeline, pipeline.id)
  end

  defp enroll_runner do
    admin_context =
      Dependencies.context(%{id: "admin-channel", role: :administrator}, Ecto.UUID.generate())

    runner_context =
      Dependencies.context(%{id: "anonymous", role: :runner}, Ecto.UUID.generate())

    assert {:ok, enrollment} = Runners.create_enrollment_token(%{}, admin_context)

    assert {:ok, identity} =
             Runners.enroll(%{token: enrollment.token, name: "channel-runner"}, runner_context)

    {identity, admin_context}
  end

  defp connect_runner(identity) do
    connect(RobineWeb.RunnerSocket, %{},
      connect_info: %{
        x_headers: [
          {"x-robine-runner-id", identity.runner_id},
          {"x-robine-runner-credential", identity.credential}
        ]
      }
    )
  end
end
