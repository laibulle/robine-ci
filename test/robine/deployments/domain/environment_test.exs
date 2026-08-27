defmodule Robine.Deployments.Domain.EnvironmentTest do
  use ExUnit.Case, async: true

  alias Robine.Deployments.Domain.Environment

  @now ~U[2026-08-27 17:00:00.000000Z]

  test "accepts one application plus bounded persistent services" do
    assert {:ok, environment} = Environment.new(valid_input())
    assert environment.protection == :protected
    assert Enum.map(environment.services, & &1.role) == [:postgres, :application]
    assert byte_size(environment.desired_state_digest) == 64
  end

  test "requires exactly one application and confines the deployment root" do
    assert {:error, {:invalid_environment, :services}} =
             valid_input()
             |> Map.put(:services, [postgres_service()])
             |> Environment.new()

    assert {:error, {:invalid_environment, :deployment_root}} =
             valid_input()
             |> Map.put(:deployment_root, "/opt/robine/../other")
             |> Environment.new()
  end

  defp valid_input do
    %{
      id: "environment-1",
      repository_id: "repository-1",
      name: "production",
      protection: :protected,
      runner_labels: ["production", "amd64"],
      deployment_root: "/opt/robine",
      network_name: "robine-production",
      timeout_ms: 1_200_000,
      migration_policy: :forward_only,
      verification: %{
        url: "https://ci.example.test/health/ready",
        expected_status: 200..299,
        version_path: "/health/version"
      },
      services: [postgres_service(), application_service()],
      inserted_at: @now,
      updated_at: @now
    }
  end

  defp postgres_service do
    %{
      role: :postgres,
      name: "postgres",
      image: "postgres:18-alpine@sha256:#{String.duplicate("a", 64)}",
      volumes: [%{name: "postgres-data", mount_path: "/var/lib/postgresql"}],
      healthcheck: %{type: :tcp, port: 5432}
    }
  end

  defp application_service do
    %{
      role: :application,
      name: "server",
      image: "hexpm/elixir@sha256:#{String.duplicate("b", 64)}",
      healthcheck: %{type: :http, url: "http://server:4000/health/ready"}
    }
  end
end
