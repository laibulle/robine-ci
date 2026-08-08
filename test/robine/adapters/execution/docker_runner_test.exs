defmodule Robine.Adapters.Execution.DockerRunnerTest do
  use ExUnit.Case, async: false

  alias Robine.Adapters.Execution.DockerRunner
  alias Robine.Execution.Contracts.{Specification, Step}

  @tag :docker
  test "runs sequential steps in one container and always cleans resources" do
    attempt_id = "docker-test-#{System.unique_integer([:positive])}"

    specification = %Specification{
      version: 1,
      attempt_id: attempt_id,
      image: "postgres:18-alpine",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      env: %{"VISIBLE" => "yes"},
      secrets: %{},
      steps: [
        %Step{name: "Write", kind: :run, value: "printf shared > state.txt"},
        %Step{name: "Read", kind: :run, value: "printf '%s:%s' \"$(cat state.txt)\" \"$VISIBLE\""}
      ]
    }

    assert {:ok, result} = DockerRunner.run(specification)
    assert result.status == :succeeded
    assert Enum.at(result.steps, 1).output == "shared:yes"
    assert result.cleanup_warning == nil

    suffix =
      :crypto.hash(:sha256, attempt_id) |> Base.encode16(case: :lower) |> binary_part(0, 20)

    resource = "robine-#{suffix}"

    {_output, exit_code} =
      System.cmd("docker", ["container", "inspect", resource], stderr_to_stdout: true)

    assert exit_code == 1
  end

  @tag :docker
  test "stops after a command failure and returns its output" do
    specification = %Specification{
      version: 1,
      attempt_id: "docker-failure-#{System.unique_integer([:positive])}",
      image: "postgres:18-alpine",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      env: %{},
      secrets: %{},
      steps: [
        %Step{name: "Fail", kind: :run, value: "echo broken; exit 7"},
        %Step{name: "Never", kind: :run, value: "echo no"}
      ]
    }

    assert {:ok, result} = DockerRunner.run(specification)
    assert result.status == :failed
    assert result.reason == :command_failed
    assert [%{name: "Fail", exit_code: 7, output: "broken\n"}] = result.steps
  end
end
