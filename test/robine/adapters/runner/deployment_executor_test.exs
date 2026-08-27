defmodule Robine.Adapters.Runner.DeploymentExecutorTest do
  use ExUnit.Case, async: true

  alias Robine.Adapters.Runner.DeploymentExecutor
  alias Robine.TestSupport.DeploymentExecutorAdapter

  test "fails closed before extraction or Docker effects when the artifact digest differs" do
    root =
      Path.join(
        System.tmp_dir!(),
        "robine-deployment-executor-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    event_agent = start_supervised!({Agent, fn -> [] end})
    body = "tampered artifact"

    config = %{
      "runner_id" => Ecto.UUID.generate(),
      "credential" => "rrc_secret",
      "deployment_roots" => [root],
      :artifact_body => body,
      :event_agent => event_agent,
      :event_adapter => DeploymentExecutorAdapter,
      :request_adapter => DeploymentExecutorAdapter
    }

    assert {:error, :artifact_integrity_failed} =
             DeploymentExecutor.run(offer(root), self(), config)

    events = Agent.get(event_agent, &Enum.reverse/1)

    assert [
             %{"sequence" => 2, "status" => "converging_services"},
             %{
               "sequence" => 3,
               "status" => "failed",
               "reason" => "artifact_integrity_failed"
             }
           ] = events

    refute File.exists?(Path.join(root, "releases"))
  end

  defp offer(root) do
    now = DateTime.to_iso8601(~U[2026-08-27 17:00:00.000000Z])

    %{
      "deployment_id" => Ecto.UUID.generate(),
      "idempotency_token" => Ecto.UUID.generate(),
      "kind" => "application",
      "artifact_url" => "https://ci.example.test/artifact",
      "secrets_url" => "https://ci.example.test/secrets",
      "artifact" => %{
        "digest" => String.duplicate("a", 64),
        "filename" => "release.tar.gz"
      },
      "environment" => %{
        "id" => Ecto.UUID.generate(),
        "repository_id" => Ecto.UUID.generate(),
        "name" => "production",
        "protection" => "protected",
        "runner_labels" => ["production"],
        "deployment_root" => root,
        "network_name" => "robine-production",
        "timeout_ms" => 1_200_000,
        "migration_policy" => "rollback_safe",
        "verification" => %{
          "url" => "https://ci.example.test/health",
          "expected_status" => %{"first" => 200, "last" => 299},
          "version_path" => "/version"
        },
        "services" => [
          %{
            "role" => "application",
            "name" => "server",
            "image" => "hexpm/elixir@sha256:#{String.duplicate("b", 64)}",
            "command" => ["/opt/robine/bin/robine", "start"],
            "environment" => %{},
            "secret_environment" => %{},
            "volumes" => [],
            "healthcheck" => %{}
          }
        ],
        "inserted_at" => now,
        "updated_at" => now
      }
    }
  end
end
