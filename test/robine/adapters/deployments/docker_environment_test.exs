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

  test "application activation converges one idempotent bundled runner without exposing Docker to Phoenix" do
    agent = start_supervised!({Agent, fn -> docker_state() end})
    docker = stateful_docker(agent)
    digest = String.duplicate("c", 64)
    release_path = "/opt/robine/releases/#{digest}"
    environment = environment()

    options = [
      docker: docker,
      instance_id: "test-instance",
      service_roles: [:application],
      release_path: release_path,
      artifact_digest: digest
    ]

    secrets = %{"secret-key-base" => "application-secret"}

    assert {:ok, first} =
             DockerEnvironment.converge(environment, :application, secrets, options)

    assert Enum.map(first.services, &{&1.role, &1.action}) == [
             {:application, :created},
             {:bundled_runner, :created}
           ]

    assert {:ok, second} =
             DockerEnvironment.converge(environment, :application, secrets, options)

    assert Enum.map(second.services, &{&1.role, &1.action}) == [
             {:application, :unchanged},
             {:bundled_runner, :unchanged}
           ]

    calls = Agent.get(agent, &Enum.reverse(&1.calls))
    creates = Enum.filter(calls, &match?(["container", "create" | _rest], &1))
    assert length(creates) == 2

    server_create = Enum.find(creates, &(option(&1, "--name") == "server"))
    runner_create = Enum.find(creates, &(option(&1, "--name") == "server-runner"))

    assert "server-runner-bootstrap:/var/lib/robine-runner-bootstrap" in server_create
    refute Enum.any?(server_create, &String.contains?(&1, "docker.sock"))
    refute "server-runner-state:/var/lib/robine-runner" in server_create

    assert "#{release_path}:/opt/robine:ro" in runner_create
    assert "server-runner-bootstrap:/var/lib/robine-runner-bootstrap" in runner_create
    assert "server-runner-state:/var/lib/robine-runner" in runner_create
    assert "/var/run/docker.sock:/var/run/docker.sock" in runner_create
    assert "ROBINE_PUBLIC_URL=https://ci.example.test" in runner_create
    refute Enum.any?(runner_create, &String.contains?(&1, "secret-key-base"))
    refute "--env-file" in runner_create
  end

  test "explicitly disabling bundled capacity removes only the owned companion and preserves volumes" do
    agent = start_supervised!({Agent, fn -> docker_state() end})
    docker = stateful_docker(agent)
    digest = String.duplicate("d", 64)

    options = [
      docker: docker,
      instance_id: "test-instance",
      service_roles: [:application],
      release_path: "/opt/robine/releases/#{digest}",
      artifact_digest: digest
    ]

    secrets = %{"secret-key-base" => "application-secret"}

    assert {:ok, _enabled} =
             DockerEnvironment.converge(environment(), :application, secrets, options)

    disabled = environment(%{"ROBINE_BUNDLED_RUNNER_ENABLED" => "false"})

    assert {:ok, result} =
             DockerEnvironment.converge(disabled, :application, secrets, options)

    assert Enum.any?(
             result.services,
             &match?(%{role: :bundled_runner, action: :removed}, &1)
           )

    calls = Agent.get(agent, & &1.calls)
    assert ["container", "rm", "--force", "server-runner"] in calls
    refute Enum.any?(calls, &(Enum.take(&1, 2) == ["volume", "rm"]))
  end

  defp environment(application_environment \\ %{}) do
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
            environment: application_environment,
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

  defp docker_state do
    %{calls: [], networks: %{}, volumes: %{}, containers: %{}}
  end

  defp stateful_docker(agent) do
    fn arguments ->
      Agent.get_and_update(agent, fn state ->
        state = update_in(state.calls, &[arguments | &1])

        case arguments do
          [kind, "inspect" | _rest] when kind in ["network", "volume", "container"] ->
            collection = String.to_existing_atom(kind <> "s")
            name = List.last(arguments)

            case get_in(state, [collection, name]) do
              nil -> {{:error, :not_found}, state}
              labels -> {{:ok, Jason.encode!(labels)}, state}
            end

          ["network", "create" | _rest] ->
            name = List.last(arguments)
            labels = labels_from(arguments)
            {{:ok, name}, put_in(state, [:networks, name], labels)}

          ["volume", "create" | _rest] ->
            name = List.last(arguments)
            labels = labels_from(arguments)
            {{:ok, name}, put_in(state, [:volumes, name], labels)}

          ["container", "create" | _rest] ->
            name = option(arguments, "--name")
            labels = labels_from(arguments)
            {{:ok, name}, put_in(state, [:containers, name], labels)}

          ["container", "rm", "--force", name] ->
            {{:ok, name}, update_in(state.containers, &Map.delete(&1, name))}

          _other ->
            {{:ok, "ok"}, state}
        end
      end)
    end
  end

  defp labels_from(arguments) do
    arguments
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(%{}, fn
      ["--label", value], labels ->
        case String.split(value, "=", parts: 2) do
          [key, item] -> Map.put(labels, key, item)
          _invalid -> labels
        end

      _pair, labels ->
        labels
    end)
  end

  defp option(arguments, name) do
    case Enum.find_index(arguments, &(&1 == name)) do
      nil -> nil
      index -> Enum.at(arguments, index + 1)
    end
  end
end
