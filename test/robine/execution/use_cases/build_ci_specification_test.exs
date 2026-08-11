defmodule Robine.Execution.UseCases.BuildCiSpecificationTest do
  use ExUnit.Case, async: true

  alias Robine.{Execution, ExecutionContext}

  test "resolves service secrets only into the inspect-safe in-memory contract" do
    secret = "service-contract-secret"

    persisted = %{
      "attempt_id" => "attempt-service",
      "idempotency_token" => "token-service",
      "image" => "alpine:3.22",
      "env" => %{},
      "secret_names" => ["TEST_DB_PASSWORD"],
      "resolved_secrets" => %{"TEST_DB_PASSWORD" => secret},
      "services" => %{
        "docker" => %{
          "id" => "docker",
          "image" => "docker:28-dind",
          "privileged" => true,
          "env" => %{"DOCKER_TLS_CERTDIR" => ""},
          "secret_env" => %{},
          "command" => [],
          "readiness" => %{"tcp" => 2375, "timeout_ms" => 60_000}
        },
        "postgres" => %{
          "id" => "postgres",
          "image" => "postgres:18-alpine",
          "env" => %{"POSTGRES_DB" => "app_test"},
          "secret_env" => %{"POSTGRES_PASSWORD" => "TEST_DB_PASSWORD"},
          "command" => [],
          "readiness" => %{"tcp" => 5432, "timeout_ms" => 45_000}
        }
      },
      "steps" => [
        %{"name" => "Test", "kind" => "run", "value" => "true", "with" => %{}}
      ]
    }

    context = ExecutionContext.new(%{id: "admin", role: :administrator}, "service-ci", %{})

    assert {:ok, specification} =
             Execution.build_ci_specification(%{persisted: persisted, source_path: nil}, context)

    assert [docker, postgres] = specification.services
    assert docker.privileged
    assert docker.secret_env == %{}
    assert postgres.secret_env == %{"POSTGRES_PASSWORD" => secret}
    refute inspect(specification) =~ secret
    refute inspect(postgres) =~ secret
  end

  test "fails safely when persisted service secret metadata is inconsistent" do
    persisted = %{
      "attempt_id" => "attempt-service",
      "idempotency_token" => "token-service",
      "image" => "alpine:3.22",
      "secret_names" => [],
      "resolved_secrets" => %{},
      "services" => %{
        "postgres" => %{
          "id" => "postgres",
          "image" => "postgres:18-alpine",
          "secret_env" => %{"PASSWORD" => "MISSING"}
        }
      },
      "steps" => [
        %{"name" => "Test", "kind" => "run", "value" => "true", "with" => %{}}
      ]
    }

    context = ExecutionContext.new(%{id: "admin", role: :administrator}, "service-ci", %{})

    assert {:error, {:service_secret_missing, "MISSING"}} =
             Execution.build_ci_specification(%{persisted: persisted, source_path: nil}, context)
  end

  test "injects authoritative build provenance over workflow environment" do
    sha = String.duplicate("d", 40)

    persisted = %{
      "attempt_id" => "attempt-build-info",
      "idempotency_token" => "token-build-info",
      "image" => "alpine:3.22",
      "env" => %{"ROBINE_BUILD_COMMIT_SHA" => "forged", "APP_ENV" => "release"},
      "build_env" => %{
        "ROBINE_BUILD_COMMIT_SHA" => sha,
        "ROBINE_BUILD_REF_NAME" => "v1.2.3",
        "ROBINE_BUILD_REF_TYPE" => "tag",
        "ROBINE_BUILD_TIMESTAMP" => "2026-08-11T20:01:02Z",
        "ROBINE_BUILD_PIPELINE_ID" => "pipeline-build-info",
        "ROBINE_BUILD_TRIGGER" => "tag"
      },
      "steps" => [%{"name" => "Build", "kind" => "run", "value" => "true"}]
    }

    context = ExecutionContext.new(%{id: "admin", role: :administrator}, "build-info", %{})

    assert {:ok, specification} =
             Execution.build_ci_specification(%{persisted: persisted, source_path: nil}, context)

    assert specification.env["APP_ENV"] == "release"
    assert specification.env["ROBINE_BUILD_COMMIT_SHA"] == sha
    assert specification.env["ROBINE_BUILD_REF_NAME"] == "v1.2.3"
  end

  test "rejects malformed build provenance at the execution boundary" do
    persisted = %{
      "attempt_id" => "attempt-build-info",
      "idempotency_token" => "token-build-info",
      "image" => "alpine:3.22",
      "build_env" => "not-a-map",
      "steps" => [%{"name" => "Build", "kind" => "run", "value" => "true"}]
    }

    context = ExecutionContext.new(%{id: "admin", role: :administrator}, "build-info", %{})

    assert {:error, :invalid_build_environment} =
             Execution.build_ci_specification(%{persisted: persisted, source_path: nil}, context)
  end
end
