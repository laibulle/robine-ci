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

    assert [service] = specification.services
    assert service.secret_env == %{"POSTGRES_PASSWORD" => secret}
    refute inspect(specification) =~ secret
    refute inspect(service) =~ secret
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
end
