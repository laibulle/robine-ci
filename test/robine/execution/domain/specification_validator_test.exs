defmodule Robine.Execution.Domain.SpecificationValidatorTest do
  use ExUnit.Case, async: true

  alias Robine.Execution.Contracts.{Service, Specification, Step}
  alias Robine.Execution.Domain.SpecificationValidator

  test "accepts a complete version 1 execution contract" do
    assert :ok = SpecificationValidator.validate(specification())
  end

  test "rejects unsafe workspaces, invalid environment and duplicate steps" do
    assert {:error, {:invalid_specification, :workspace}} =
             specification(workspace: "../host") |> SpecificationValidator.validate()

    assert {:error, {:invalid_specification, :env}} =
             specification(env: %{"BAD-NAME" => "value"}) |> SpecificationValidator.validate()

    duplicate = %Step{name: "Test", kind: :run, value: "true"}

    assert {:error, {:invalid_specification, :steps}} =
             specification(steps: [duplicate, duplicate]) |> SpecificationValidator.validate()
  end

  test "debug inspection never renders plaintext secrets" do
    secret = "inspection-fixture-secret"

    service = %Service{
      id: "postgres",
      image: "postgres:18-alpine",
      secret_env: %{"POSTGRES_PASSWORD" => secret}
    }

    rendered = inspect(specification(secrets: %{"TOKEN" => secret}, services: [service]))

    refute rendered =~ secret
    refute rendered =~ "TOKEN"
    refute rendered =~ "POSTGRES_PASSWORD"
  end

  test "rejects malformed and duplicate normalized services" do
    service = %Service{id: "postgres", image: "postgres:18-alpine"}

    assert :ok = specification(services: [service]) |> SpecificationValidator.validate()

    assert {:error, {:invalid_specification, :services}} =
             specification(services: [service, service]) |> SpecificationValidator.validate()

    invalid = %{service | readiness: %{tcp: 70_000, timeout_ms: 1}}

    assert {:error, {:invalid_specification, :services}} =
             specification(services: [invalid]) |> SpecificationValidator.validate()
  end

  defp specification(overrides \\ []) do
    defaults = [
      version: 1,
      attempt_id: "attempt",
      image: "postgres:18-alpine",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 10_000,
      env: %{"MIX_ENV" => "test"},
      secrets: %{},
      steps: [%Step{name: "Test", kind: :run, value: "true"}]
    ]

    struct!(Specification, Keyword.merge(defaults, overrides))
  end
end
