defmodule Robine.Deployments.DeploymentLifecycleTest do
  use Robine.DataCase, async: false

  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    Artifact,
    Attempt,
    AuditEvent,
    Deployment,
    DeploymentEnvironment,
    DeploymentEvent,
    GitHubRepository,
    Job,
    Pipeline,
    RemoteRunner
  }

  alias Robine.{Deployments, Repo}
  alias Robine.Runtime.Dependencies

  @now ~U[2026-08-27 17:00:00.000000Z]

  setup do
    repository_id = Ecto.UUID.generate()
    pipeline_id = Ecto.UUID.generate()
    job_id = Ecto.UUID.generate()
    attempt_id = Ecto.UUID.generate()
    artifact_id = Ecto.UUID.generate()
    runner_id = Ecto.UUID.generate()

    GitHubRepository.changeset(%GitHubRepository{}, %{
      id: repository_id,
      provider: :github,
      provider_instance: "github.com",
      provider_id: System.unique_integer([:positive]),
      installation_id: System.unique_integer([:positive]),
      owner: "laibulle",
      name: "robine-ci",
      full_name: "laibulle/robine-ci-#{repository_id}",
      trusted: true,
      inserted_at: @now
    })
    |> Repo.insert!()

    Pipeline.changeset(%Pipeline{}, %{
      id: pipeline_id,
      repository_id: repository_id,
      workflow_name: "Robine Release",
      commit_sha: String.duplicate("d", 40),
      source_ref: "v0.2.0",
      trigger: "push",
      actor: "alice",
      correlation_id: "release-correlation",
      status: :succeeded,
      inputs: %{"tag" => "v0.2.0"},
      inserted_at: @now,
      started_at: @now,
      finished_at: @now
    })
    |> Repo.insert!()

    Job.changeset(%Job{}, %{
      id: job_id,
      pipeline_id: pipeline_id,
      job_key: "package",
      status: :succeeded,
      needs: [],
      position: 0
    })
    |> Repo.insert!()

    Attempt.changeset(%Attempt{}, %{
      id: attempt_id,
      job_id: job_id,
      number: 1,
      idempotency_token: Ecto.UUID.generate(),
      status: :succeeded,
      lease_expires_at: DateTime.add(@now, 60, :second),
      last_sequence: 3
    })
    |> Repo.insert!()

    Artifact.changeset(%Artifact{}, %{
      id: artifact_id,
      repository_id: repository_id,
      attempt_id: attempt_id,
      name: "robine-server-linux-amd64.tar.gz",
      blob_id: String.duplicate("c", 64),
      digest: String.duplicate("c", 64),
      size: 4096,
      created_at: @now,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })
    |> Repo.insert!()

    RemoteRunner.changeset(%RemoteRunner{}, %{
      id: runner_id,
      name: "deployment-runner",
      admin_state: :enabled,
      capabilities: %{"docker" => true, "deployments" => true},
      labels: ["production", "amd64"],
      inserted_at: @now,
      updated_at: @now
    })
    |> Repo.insert!()

    %{
      repository_id: repository_id,
      artifact_id: artifact_id,
      attempt_id: attempt_id,
      runner_id: runner_id
    }
  end

  test "configures, approves, projects, and audits one exact deployment", context do
    admin = Dependencies.context(%{id: "admin", role: :administrator}, "configure-deployment")

    assert {:ok, environment} =
             Deployments.configure_environment(environment_input(context.repository_id), admin)

    maintainer =
      Dependencies.context(%{id: "maintainer", role: :maintainer}, "request-deployment")

    assert {:ok, requested} =
             Deployments.request_deployment(
               %{environment_id: environment.id, artifact_id: context.artifact_id},
               maintainer
             )

    assert requested.status == :awaiting_approval
    assert requested.artifact.digest == String.duplicate("c", 64)

    assert {:ok, repeated} =
             Deployments.request_deployment(
               %{environment_id: environment.id, artifact_id: context.artifact_id},
               maintainer
             )

    assert repeated.id == requested.id

    self_admin = Dependencies.context(%{id: "maintainer", role: :administrator}, "self-approve")

    assert {:error, :self_approval} =
             Deployments.approve_deployment(%{deployment_id: requested.id}, self_admin)

    approver = Dependencies.context(%{id: "approver", role: :administrator}, "approve")

    assert {:ok, approved} =
             Deployments.approve_deployment(%{deployment_id: requested.id}, approver)

    assert approved.status == :queued

    dispatcher =
      Dependencies.context(%{id: "system:dispatcher", role: :administrator}, "assign-deployment")

    assert {:ok, assigned} =
             Deployments.assign_deployment(
               %{
                 deployment_id: requested.id,
                 runner_id: context.runner_id,
                 lease_seconds: 60
               },
               dispatcher
             )

    runner = Dependencies.context(%{id: context.runner_id, role: :runner}, "runner-events")

    assert {:error, :stale_deployment_attempt} =
             Deployments.record_runner_event(
               %{
                 deployment_id: requested.id,
                 idempotency_token: Ecto.UUID.generate(),
                 message_id: Ecto.UUID.generate(),
                 sequence: 1,
                 status: :preparing
               },
               runner
             )

    events =
      [
        {1, :preparing},
        {2, :migrating},
        {3, :activating},
        {4, :verifying},
        {5, :succeeded}
      ]
      |> Enum.map(fn {sequence, status} -> {sequence, status, Ecto.UUID.generate()} end)

    final =
      events
      |> Enum.reduce(assigned, fn {sequence, status, message_id}, _deployment ->
        assert {:ok, projected} =
                 Deployments.record_runner_event(
                   %{
                     deployment_id: requested.id,
                     idempotency_token: assigned.idempotency_token,
                     message_id: message_id,
                     sequence: sequence,
                     status: status
                   },
                   runner
                 )

        projected
      end)

    {last_sequence, last_status, last_message_id} = List.last(events)

    assert {:ok, replayed} =
             Deployments.record_runner_event(
               %{
                 deployment_id: requested.id,
                 idempotency_token: assigned.idempotency_token,
                 message_id: last_message_id,
                 sequence: last_sequence,
                 status: last_status
               },
               runner
             )

    assert replayed.status == :succeeded

    other_runner =
      Dependencies.context(%{id: Ecto.UUID.generate(), role: :runner}, "foreign-runner")

    assert {:error, :not_found} =
             Deployments.record_runner_event(
               %{
                 deployment_id: requested.id,
                 idempotency_token: assigned.idempotency_token,
                 message_id: Ecto.UUID.generate(),
                 sequence: 6,
                 status: :failed,
                 reason: "forged"
               },
               other_runner
             )

    assert final.status == :succeeded
    assert Repo.get!(Deployment, requested.id).event_sequence == 5
    assert Repo.aggregate(DeploymentEvent, :count) == 5
    assert Repo.aggregate(DeploymentEnvironment, :count) == 1

    actions = Repo.all(from event in AuditEvent, select: event.action)
    assert "deployment.environment_configured" in actions
    assert "deployment.requested" in actions
    assert "deployment.approved" in actions
    assert Enum.count(actions, &(&1 == "deployment.phase_changed")) == 5

    assert {:ok, overview} =
             Deployments.get_repository_overview(
               %{repository_id: context.repository_id},
               approver
             )

    assert length(overview.environments) == 1
    assert hd(overview.deployments).status == :succeeded
  end

  test "allows requester cancellation before remote effects", context do
    admin = Dependencies.context(%{id: "admin", role: :administrator}, "configure-cancel")

    assert {:ok, environment} =
             Deployments.configure_environment(environment_input(context.repository_id), admin)

    maintainer = Dependencies.context(%{id: "maintainer", role: :maintainer}, "request-cancel")

    assert {:ok, requested} =
             Deployments.request_deployment(
               %{environment_id: environment.id, artifact_id: context.artifact_id},
               maintainer
             )

    assert {:ok, cancelled} =
             Deployments.cancel_deployment(%{deployment_id: requested.id}, maintainer)

    assert cancelled.status == :cancelled
    assert Repo.get!(Deployment, requested.id).status == :cancelled
  end

  test "queues multiple releases but assigns only one active deployment per environment",
       context do
    second_artifact_id = Ecto.UUID.generate()

    Artifact.changeset(%Artifact{}, %{
      id: second_artifact_id,
      repository_id: context.repository_id,
      attempt_id: context.attempt_id,
      name: "robine-server-linux-amd64-second.tar.gz",
      blob_id: String.duplicate("e", 64),
      digest: String.duplicate("e", 64),
      size: 4096,
      created_at: @now,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })
    |> Repo.insert!()

    admin = Dependencies.context(%{id: "admin", role: :administrator}, "configure-queue")

    assert {:ok, environment} =
             Deployments.configure_environment(environment_input(context.repository_id), admin)

    requester = Dependencies.context(%{id: "maintainer", role: :maintainer}, "request-queue")

    assert {:ok, first} =
             Deployments.request_deployment(
               %{environment_id: environment.id, artifact_id: context.artifact_id},
               requester
             )

    assert {:ok, second} =
             Deployments.request_deployment(
               %{environment_id: environment.id, artifact_id: second_artifact_id},
               requester
             )

    approver = Dependencies.context(%{id: "approver", role: :administrator}, "approve-queue")
    assert {:ok, _first} = Deployments.approve_deployment(%{deployment_id: first.id}, approver)
    assert {:ok, _second} = Deployments.approve_deployment(%{deployment_id: second.id}, approver)

    assert {:ok, queued} = Deployments.next_queued_deployment(%{}, admin)
    assert queued.id == first.id

    assert {:ok, _assigned} =
             Deployments.assign_deployment(
               %{deployment_id: first.id, runner_id: context.runner_id, lease_seconds: 60},
               admin
             )

    assert {:error, :none} = Deployments.next_queued_deployment(%{}, admin)
    assert Repo.get!(Deployment, second.id).status == :queued
    assert is_nil(Repo.get!(Deployment, second.id).runner_id)
  end

  defp environment_input(repository_id) do
    %{
      repository_id: repository_id,
      name: "production",
      protection: :protected,
      runner_labels: ["production", "amd64"],
      deployment_root: "/opt/robine",
      network_name: "robine-production",
      timeout_ms: 1_200_000,
      migration_policy: :rollback_safe,
      verification: %{
        url: "https://ci.example.test/health/ready",
        expected_status: 200..299,
        version_path: "/health/version"
      },
      services: [
        %{
          role: :postgres,
          name: "postgres",
          image: "postgres:18-alpine@sha256:#{String.duplicate("a", 64)}",
          secret_environment: %{"POSTGRES_PASSWORD" => "postgres-password"},
          volumes: [%{name: "postgres-data", mount_path: "/var/lib/postgresql"}],
          healthcheck: %{type: :tcp, port: 5432}
        },
        %{
          role: :application,
          name: "server",
          image: "hexpm/elixir@sha256:#{String.duplicate("b", 64)}",
          secret_environment: %{"SECRET_KEY_BASE" => "secret-key-base"},
          healthcheck: %{type: :http, url: "http://server:4000/health/ready"}
        }
      ]
    }
  end
end
