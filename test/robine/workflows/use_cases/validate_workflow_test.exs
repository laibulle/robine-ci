defmodule Robine.Workflows.UseCases.ValidateWorkflowTest do
  use ExUnit.Case, async: true

  alias Robine.ExecutionContext
  alias Robine.Workflows
  alias Robine.Workflows.Dependencies

  defp context do
    ExecutionContext.new(%{id: "developer", role: :maintainer}, "test", %{
      workflows: %Dependencies{decoder: Robine.Adapters.Workflow.YamlDecoder}
    })
  end

  test "normalizes a valid workflow and sorts its graph" do
    source = """
    version: 1
    name: CI
    on:
      push: {}
      pull_request: {}
    jobs:
      build:
        image: alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        steps:
          - uses: checkout
          - name: Compile
            run: echo compiling
      test:
        image: alpine:3.22
        needs: build
        env:
          MIX_ENV: test
        steps:
          - name: Test
            run: echo testing
    """

    assert {:ok, result} =
             Workflows.validate(%{source: source, path: ".robine-ci/workflows/ci.yml"}, context())

    assert result.workflow.order == ["build", "test"]
    assert result.workflow.jobs["test"].needs == ["build"]
    assert [%{code: "job.image_mutable", severity: :warning}] = result.warnings
  end

  test "reports unknown keys with a stable path" do
    source = """
    version: 1
    name: CI
    on: {push: {}}
    surprise: true
    jobs: {}
    """

    assert {:error, [diagnostic]} =
             Workflows.validate(%{source: source, path: "ci.yml"}, context())

    assert diagnostic.code == "workflow.unknown_key"
    assert diagnostic.path == ["surprise"]
  end

  test "reports every member of a dependency cycle" do
    source = """
    version: 1
    name: CI
    on: {push: {}}
    jobs:
      first:
        image: alpine:3.22
        needs: second
        steps: [{run: "true"}]
      second:
        image: alpine:3.22
        needs: first
        steps: [{run: "true"}]
    """

    assert {:error, diagnostics} =
             Workflows.validate(%{source: source, path: "ci.yml"}, context())

    assert Enum.map(diagnostics, & &1.code) == ["workflow.cycle", "workflow.cycle"]
    assert Enum.map(diagnostics, &Enum.at(&1.path, 1)) == ["first", "second"]
  end

  test "rejects unsupported built-ins and malformed YAML" do
    unsupported = """
    version: 1
    name: CI
    on: {push: {}}
    jobs:
      test:
        image: alpine:3.22
        steps: [{uses: actions/checkout@v4}]
    """

    assert {:error, [%{code: "step.builtin"}]} =
             Workflows.validate(%{source: unsupported, path: "ci.yml"}, context())

    assert {:error, [%{code: "yaml.syntax"}]} =
             Workflows.validate(%{source: "jobs: [", path: "ci.yml"}, context())
  end
end
