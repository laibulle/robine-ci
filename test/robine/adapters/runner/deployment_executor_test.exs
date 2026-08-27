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
             DeploymentExecutor.run(offer(root, String.duplicate("a", 64)), self(), config)

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

  test "extracts, migrates, and activates the exact release through bounded Docker arguments" do
    root =
      Path.join(
        System.tmp_dir!(),
        "robine-deployment-success-#{System.unique_integer([:positive])}"
      )

    source = root <> "-source"
    on_exit(fn -> File.rm_rf!(root) end)
    on_exit(fn -> File.rm_rf!(source) end)

    body = release_artifact!(source)
    digest = sha256(body)
    event_agent = start_supervised!({Agent, fn -> [] end}, id: :deployment_event_agent)
    docker_agent = start_supervised!({Agent, fn -> [] end}, id: :deployment_docker_agent)

    config = %{
      "runner_id" => Ecto.UUID.generate(),
      "credential" => "rrc_secret",
      "deployment_roots" => [root],
      :artifact_body => body,
      :event_agent => event_agent,
      :docker_agent => docker_agent,
      :event_adapter => DeploymentExecutorAdapter,
      :request_adapter => DeploymentExecutorAdapter,
      :docker_adapter => DeploymentExecutorAdapter
    }

    assert :ok = DeploymentExecutor.run(offer(root, digest), self(), config)

    assert Enum.map(Agent.get(event_agent, &Enum.reverse/1), & &1["status"]) == [
             "converging_services",
             "migrating",
             "activating",
             "verifying"
           ]

    release_path = Path.join([root, "releases", digest])
    assert File.regular?(Path.join(release_path, "bin/robine"))
    assert File.read!(Path.join(release_path, ".robine-artifact-sha256")) == digest

    commands = Agent.get(docker_agent, &Enum.reverse/1)
    assert Enum.any?(commands, &match?(["container", "run", "--rm" | _rest], &1))

    assert Enum.any?(commands, fn command ->
             match?(["container", "create" | _rest], command) and
               "#{release_path}:/opt/robine:ro" in command
           end)

    refute Enum.any?(commands, &(Enum.take(&1, 2) == ["volume", "rm"]))
  end

  defp offer(root, digest) do
    now = DateTime.to_iso8601(~U[2026-08-27 17:00:00.000000Z])

    %{
      "deployment_id" => Ecto.UUID.generate(),
      "idempotency_token" => Ecto.UUID.generate(),
      "kind" => "application",
      "artifact_url" => "https://ci.example.test/artifact",
      "secrets_url" => "https://ci.example.test/secrets",
      "artifact" => %{
        "digest" => digest,
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

  defp release_artifact!(source) do
    release_root = Path.join(source, "release/robine/bin")
    outer_root = Path.join(source, "outer")
    File.mkdir_p!(release_root)
    File.mkdir_p!(outer_root)
    File.write!(Path.join(release_root, "robine"), "#!/bin/sh\n")

    server_archive = Path.join(outer_root, "robine-server-linux-amd64.tar.gz")

    {_, 0} =
      System.cmd("tar", ["-czf", server_archive, "-C", Path.join(source, "release"), "robine"])

    server_digest = server_archive |> File.read!() |> sha256()

    File.write!(
      Path.join(outer_root, "SHA256SUMS"),
      "#{server_digest}  #{Path.basename(server_archive)}\n"
    )

    outer_archive = Path.join(source, "artifact.tar.gz")

    {_, 0} =
      System.cmd("tar", [
        "-czf",
        outer_archive,
        "-C",
        outer_root,
        "SHA256SUMS",
        Path.basename(server_archive)
      ])

    File.read!(outer_archive)
  end

  defp sha256(body),
    do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
