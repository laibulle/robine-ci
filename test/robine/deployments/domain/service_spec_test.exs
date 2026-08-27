defmodule Robine.Deployments.Domain.ServiceSpecTest do
  use ExUnit.Case, async: true

  alias Robine.Deployments.Domain.ServiceSpec

  test "accepts a pinned persistent service and produces a stable desired digest" do
    input = %{
      role: :postgres,
      name: "postgres",
      image: "postgres:18-alpine@sha256:#{String.duplicate("a", 64)}",
      command: ["postgres"],
      environment: %{"POSTGRES_DB" => "robine"},
      secret_environment: %{"POSTGRES_PASSWORD" => "production-postgres-password"},
      volumes: [%{name: "postgres-data", mount_path: "/var/lib/postgresql", read_only: false}],
      healthcheck: %{type: :tcp, port: 5432, timeout_ms: 30_000}
    }

    assert {:ok, first} = ServiceSpec.new(input)
    assert {:ok, second} = ServiceSpec.new(input)
    assert first.spec_digest == second.spec_digest
    assert byte_size(first.spec_digest) == 64
  end

  test "rejects mutable images, plaintext secret collisions, and unsafe mounts" do
    base = %{
      role: :application,
      name: "server",
      image: "hexpm/elixir@sha256:#{String.duplicate("b", 64)}",
      healthcheck: %{type: :http, url: "http://server:4000/health/ready"}
    }

    assert {:error, {:invalid_service_spec, :image}} =
             ServiceSpec.new(%{base | image: "hexpm/elixir:latest"})

    assert {:error, {:invalid_service_spec, :environment_collision}} =
             ServiceSpec.new(
               Map.merge(base, %{
                 environment: %{"SECRET_KEY_BASE" => "visible"},
                 secret_environment: %{"SECRET_KEY_BASE" => "secret-key-base"}
               })
             )

    assert {:error, {:invalid_service_spec, :volumes}} =
             ServiceSpec.new(
               Map.put(base, :volumes, [
                 %{name: "root", mount_path: "/", read_only: false}
               ])
             )
  end
end
