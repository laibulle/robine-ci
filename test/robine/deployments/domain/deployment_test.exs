defmodule Robine.Deployments.Domain.DeploymentTest do
  use ExUnit.Case, async: true

  alias Robine.Deployments.Domain.{ArtifactSnapshot, Deployment, Environment}

  @now ~U[2026-08-27 17:00:00.000000Z]

  test "protected deployment fixes provenance and rejects self approval" do
    assert {:ok, deployment} =
             Deployment.new(%{id: "d1", requester_id: "alice"}, environment(), artifact(), @now)

    assert deployment.status == :awaiting_approval
    assert deployment.artifact.digest == String.duplicate("c", 64)

    assert {:error, :self_approval} = Deployment.approve(deployment, "alice", @now)
    assert {:ok, approved} = Deployment.approve(deployment, "bob", @now)
    assert approved.status == :queued
    assert approved.approver_id == "bob"
  end

  test "enforces ordered phase transitions and terminal verification outcome" do
    environment = %{environment() | protection: :unprotected}

    assert {:ok, deployment} =
             Deployment.new(%{id: "d1", requester_id: "alice"}, environment, artifact(), @now)

    assert deployment.status == :queued

    assert {:error, :invalid_event_sequence} =
             Deployment.record_event(deployment, 2, :preparing, nil, @now)

    assert {:ok, preparing} = Deployment.record_event(deployment, 1, :preparing, nil, @now)
    assert {:ok, migrating} = Deployment.record_event(preparing, 2, :migrating, nil, @now)
    assert {:ok, activating} = Deployment.record_event(migrating, 3, :activating, nil, @now)
    assert {:ok, verifying} = Deployment.record_event(activating, 4, :verifying, nil, @now)

    assert {:ok, failed} =
             Deployment.record_event(verifying, 5, :verification_failed, "version_mismatch", @now)

    assert Deployment.terminal?(failed)
    assert failed.failure_reason == "version_mismatch"
  end

  test "forbids rollback under a forward-only migration policy" do
    assert {:error, :rollback_forbidden} =
             Deployment.new(
               %{id: "d1", requester_id: "alice", kind: :rollback},
               environment(),
               artifact(),
               @now
             )
  end

  test "requires independent approval for platform convergence even in staging" do
    environment = %{environment() | protection: :unprotected}

    assert {:ok, deployment} =
             Deployment.new(
               %{id: "d1", requester_id: "alice", kind: :platform},
               environment,
               artifact(),
               @now
             )

    assert deployment.status == :awaiting_approval
    assert {:error, :self_approval} = Deployment.approve(deployment, "alice", @now)
  end

  defp environment do
    {:ok, environment} =
      Environment.new(%{
        id: "environment-1",
        repository_id: "repository-1",
        name: "production",
        protection: :protected,
        runner_labels: ["production"],
        deployment_root: "/opt/robine",
        network_name: "robine-production",
        timeout_ms: 1_200_000,
        migration_policy: :forward_only,
        verification: %{url: "https://ci.example.test/health", expected_status: 200..299},
        services: [
          %{
            role: :application,
            name: "server",
            image: "hexpm/elixir@sha256:#{String.duplicate("b", 64)}",
            healthcheck: %{type: :http, url: "http://server:4000/health"}
          }
        ],
        inserted_at: @now,
        updated_at: @now
      })

    environment
  end

  defp artifact do
    {:ok, artifact} =
      ArtifactSnapshot.new(%{
        artifact_id: "artifact-1",
        pipeline_id: "pipeline-1",
        filename: "robine-server-linux-amd64.tar.gz",
        digest: String.duplicate("c", 64),
        size: 1024,
        tag: "v0.2.0",
        commit_sha: String.duplicate("d", 40)
      })

    artifact
  end
end
