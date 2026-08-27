defmodule Robine.Adapters.Deployments.DockerEnvironmentTest do
  use ExUnit.Case, async: true

  alias Robine.Adapters.Deployments.DockerEnvironment
  alias Robine.Deployments.Domain.Environment

  @now ~U[2026-08-27 17:00:00.000000Z]

  test "platform convergence creates owned resources without exposing or deleting secrets and volumes" do
    agent = start_supervised!({Agent, fn -> [] end})

    docker = fn arguments ->
      observation =
        case Enum.find_index(arguments, &(&1 == "--env-file")) do
          nil ->
            %{arguments: arguments}

          index ->
            path = Enum.at(arguments, index + 1)
            {:ok, stat} = File.stat(path)
            %{arguments: arguments, env_mode: Bitwise.band(stat.mode, 0o777)}
        end

      Agent.update(agent, &[observation | &1])

      if "inspect" in arguments,
        do: {:error, :not_found},
        else: {:ok, "created"}
    end

    assert {:ok, result} =
             DockerEnvironment.converge(
               environment(),
               :platform,
               %{"postgres-password" => "super-secret", "secret-key-base" => "app-secret"},
               docker: docker,
               instance_id: "test-instance"
             )

    assert Enum.all?(result.services, &(&1.action == :created))

    observations = Agent.get(agent, &Enum.reverse/1)
    arguments = Enum.flat_map(observations, & &1.arguments)
    refute "super-secret" in arguments
    refute "app-secret" in arguments
    refute Enum.chunk_every(arguments, 2, 1, :discard) |> Enum.any?(&(&1 == ["volume", "rm"]))

    assert Enum.all?(
             Enum.filter(observations, &Map.has_key?(&1, :env_mode)),
             &(&1.env_mode == 0o600)
           )

    assert Enum.count(arguments, &(&1 == "start")) == 2
  end

  test "application promotion refuses to mutate a drifted persistent service" do
    environment = environment()
    postgres = Enum.find(environment.services, &(&1.role == :postgres))
    agent = start_supervised!({Agent, fn -> [] end})

    docker = fn arguments ->
      Agent.update(agent, &[arguments | &1])

      case arguments do
        ["network", "inspect" | _rest] ->
          {:ok, labels(environment)}

        ["volume", "inspect" | _rest] ->
          {:ok, labels(environment)}

        ["container", "inspect", "--format", _format, "postgres"] ->
          {:ok,
           Jason.encode!(%{
             "io.robine.instance" => "test-instance",
             "io.robine.environment" => environment.id,
             "io.robine.service-role" => "postgres",
             "io.robine.deployment-spec" => String.duplicate("0", 64)
           })}

        _arguments ->
          {:ok, "ok"}
      end
    end

    assert {:error, {:persistent_service_not_current, "postgres", :changed}} =
             DockerEnvironment.converge(
               environment,
               :application,
               %{"postgres-password" => "secret", "secret-key-base" => "app-secret"},
               docker: docker,
               instance_id: "test-instance"
             )

    commands = Agent.get(agent, & &1)
    refute Enum.any?(commands, &match?(["container", "rm", "--force", "postgres"], &1))
    assert postgres.spec_digest != String.duplicate("0", 64)
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
        migration_policy: :rollback_safe,
        verification: %{url: "https://ci.example.test/health", expected_status: 200..299},
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
            healthcheck: %{type: :http, url: "http://server:4000/health"}
          }
        ],
        inserted_at: @now,
        updated_at: @now
      })

    environment
  end

  defp labels(environment) do
    Jason.encode!(%{
      "io.robine.instance" => "test-instance",
      "io.robine.environment" => environment.id
    })
  end
end
