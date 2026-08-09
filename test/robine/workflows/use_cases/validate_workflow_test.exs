defmodule Robine.Workflows.UseCases.ValidateWorkflowTest do
  use ExUnit.Case, async: true

  alias Robine.ExecutionContext
  alias Robine.Workflows
  alias Robine.Workflows.Dependencies
  alias Robine.Workflows.Domain.Validator

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
        secrets: [REGISTRY_TOKEN]
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
    assert result.workflow.jobs["test"].secrets == ["REGISTRY_TOKEN"]
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
    assert {diagnostic.line, diagnostic.column} == {4, 1}
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
    assert Enum.map(diagnostics, &{&1.line, &1.column}) == [{7, 5}, {11, 5}]
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

    assert {:error, [%{code: "yaml.syntax", line: line, column: column}]} =
             Workflows.validate(%{source: "jobs: [", path: "ci.yml"}, context())

    assert {line, column} == {1, 8}
  end

  test "normalizes the exact built-in input contracts" do
    yaml = """
    version: 1
    name: Built-ins
    on:
      push: {}
    jobs:
      build:
        image: alpine:3.22
        steps:
          - uses: checkout
          - uses: cache/restore
            with:
              key: mix-${{ checksum('mix.lock') }}
              paths: [deps, _build]
          - uses: cache/save
            with:
              key: mix-${{ checksum('mix.lock') }}
              paths: [deps, _build]
          - uses: artifacts/upload
            with:
              name: reports
              paths: [cover]
              retention-days: 14
      report:
        image: alpine:3.22
        needs: build
        steps:
          - uses: artifacts/download
            with:
              name: reports
              from: build
              path: imported
    """

    assert {:ok, workflow, warnings} = validate(yaml)
    assert length(warnings) == 2

    assert workflow.jobs["build"].steps |> Enum.at(1) |> Map.fetch!(:with) |> Map.fetch!("paths") ==
             ["deps", "_build"]

    assert workflow.jobs["report"].steps |> hd() |> Map.fetch!(:with) |> Map.fetch!("path") ==
             "imported"
  end

  test "rejects unsafe, missing, and unknown built-in inputs" do
    cases = [
      {"cache/restore", "{key: deps, paths: [../outside]}", "step.cache_inputs"},
      {"cache/save", "{key: '${{ env.SECRET }}', paths: [deps]}", "step.cache_inputs"},
      {"artifacts/upload", "{name: ../../escape, paths: [cover]}", "step.artifact_upload_inputs"},
      {"artifacts/download", "{name: reports, from: ../build}", "step.artifact_download_inputs"},
      {"cache/save", "{key: deps, paths: [deps], surprise: true}", "workflow.unknown_key"}
    ]

    for {builtin, inputs, code} <- cases do
      yaml = """
      version: 1
      name: Invalid built-in
      on:
        push: {}
      jobs:
        test:
          image: alpine:3.22
          steps:
            - uses: #{builtin}
              with: #{inputs}
      """

      assert {:error, diagnostics} = validate(yaml)

      assert Enum.any?(diagnostics, &(&1.code == code)),
             "expected #{code} for #{builtin}, got #{inspect(diagnostics)}"
    end
  end

  test "requires artifact producers to be direct declared dependencies" do
    yaml = """
    version: 1
    name: Artifacts
    on: {push: {}}
    jobs:
      build:
        image: alpine:3.22
        steps: [{run: "true"}]
      test:
        image: alpine:3.22
        steps:
          - uses: artifacts/download
            with: {name: release, from: build}
    """

    assert {:error, diagnostics} = validate(yaml)
    assert [%{code: "step.artifact_dependency"}] = diagnostics
  end

  test "rejects workflow source above the configured byte limit before YAML decoding" do
    source = String.duplicate("# padding\n", 30_000)

    assert {:error, [%{code: "workflow.limit_source_bytes"}]} =
             Workflows.validate(%{source: source, path: "large.yml"}, context())
  end

  test "enforces job, step, total-step, and graph-depth limits with stable codes" do
    job = fn needs, steps ->
      %{
        "image" => "alpine:3.22",
        "needs" => needs,
        "steps" => Enum.map(1..steps, &%{"run" => "echo #{&1}"})
      }
    end

    limits = [max_jobs: 1, max_steps_per_job: 1, max_total_steps: 1, max_graph_depth: 1]

    assert {:error, [%{code: "workflow.limit_jobs"}]} =
             Validator.validate(document(%{"a" => job.([], 1), "b" => job.([], 1)}), limits)

    assert {:error, [%{code: "workflow.limit_steps_per_job"}]} =
             Validator.validate(document(%{"a" => job.([], 2)}), limits)

    total_limits = Keyword.merge(limits, max_jobs: 2, max_steps_per_job: 2)

    assert {:error, [%{code: "workflow.limit_total_steps"}]} =
             Validator.validate(
               document(%{"a" => job.([], 1), "b" => job.([], 1)}),
               total_limits
             )

    depth_limits = Keyword.merge(limits, max_jobs: 2, max_total_steps: 2)

    assert {:error, [%{code: "workflow.limit_graph_depth"}]} =
             Validator.validate(
               document(%{"a" => job.([], 1), "b" => job.(["a"], 1)}),
               depth_limits
             )
  end

  test "accepts only the two explicit shell contracts" do
    valid =
      document(%{
        "test" => %{"image" => "alpine", "shell" => "/bin/bash", "steps" => [%{"run" => "true"}]}
      })

    assert {:ok, workflow, _warnings} = Validator.validate(valid)
    assert workflow.jobs["test"].shell == "/bin/bash"

    invalid = put_in(valid, ["jobs", "test", "shell"], "/usr/bin/fish")
    assert {:error, [%{code: "job.shell"}]} = Validator.validate(invalid)
  end

  defp validate(source) do
    case Workflows.validate(%{source: source, path: "builtins.yml"}, context()) do
      {:ok, result} -> {:ok, result.workflow, result.warnings}
      error -> error
    end
  end

  defp document(jobs),
    do: %{"version" => 1, "name" => "Limits", "on" => %{"push" => %{}}, "jobs" => jobs}
end
