defmodule Robine.Workflows.UseCases.ResolveWorkflowTest do
  use ExUnit.Case, async: true

  alias Robine.Runtime.Dependencies
  alias Robine.Workflows

  @entry ".robine-ci/workflows/ci.yml"
  @quality ".robine-ci/workflows/quality.yml"
  @security ".robine-ci/workflows/security.yml"

  test "composes nested namespaced jobs and isolates typed inputs to direct jobs" do
    assert {:ok, validated} =
             Workflows.resolve(
               %{entry_path: @entry, sources: valid_sources()},
               Dependencies.local_context()
             )

    assert validated.workflow.order == [
             "quality--security--scan",
             "quality--test",
             "package"
           ]

    scan = validated.workflow.jobs["quality--security--scan"]
    test = validated.workflow.jobs["quality--test"]
    package = validated.workflow.jobs["package"]

    assert scan.env["ROBINE_CALL_INPUT_STRICT"] == "true"
    refute Map.has_key?(scan.env, "ROBINE_CALL_INPUT_RUNTIME")
    assert test.env["ROBINE_CALL_INPUT_RUNTIME"] == "3.22"
    refute Map.has_key?(test.env, "ROBINE_CALL_INPUT_STRICT")
    assert test.needs == ["quality--security--scan"]
    assert package.needs == ["quality--test"]
    assert Map.keys(validated.sources) |> Enum.sort() == Enum.sort([@entry, @quality, @security])
  end

  test "locates call-input environment collisions in the included source" do
    sources =
      put_in(
        valid_sources(),
        [@quality],
        String.replace(
          valid_sources()[@quality],
          "env:\n      EXISTING: safe",
          "env:\n      ROBINE_CALL_INPUT_RUNTIME: forged"
        )
      )

    assert {:error, [diagnostic]} =
             Workflows.resolve(
               %{entry_path: @entry, sources: sources},
               Dependencies.local_context()
             )

    assert diagnostic.code == "call_input.env_collision"
    assert diagnostic.source_path == @quality
    assert diagnostic.path == ["jobs", "test", "env", "ROBINE_CALL_INPUT_RUNTIME"]
    assert is_integer(diagnostic.line)
    assert is_integer(diagnostic.column)
  end

  test "rejects missing files, undeclared inputs, cycles, and generated ID overflow" do
    missing = Map.delete(valid_sources(), @security)
    assert_error(missing, "include.missing", @quality)

    undeclared =
      update_in(valid_sources(), [@entry], fn source ->
        String.replace(source, "runtime: \"3.22\"", "runtime: \"3.22\"\n      forged: value")
      end)

    assert_error(undeclared, "call_input.undeclared", @quality)

    cycle =
      update_in(valid_sources(), [@security], fn source ->
        String.replace(
          source,
          "jobs:",
          "includes:\n  root:\n    path: #{@quality}\njobs:"
        )
      end)

    assert_error(cycle, "include.cycle", @security)

    long_job = String.duplicate("a", 60)

    overflow =
      update_in(valid_sources(), [@quality], fn source ->
        String.replace(source, "  test:\n", "  #{long_job}:\n")
      end)

    assert_error(overflow, "include.job_id", @quality)
  end

  test "enforces maximum include depth and transitive edge count" do
    depth_paths = Enum.map(1..5, &".robine-ci/workflows/depth-#{&1}.yml")

    depth_sources =
      depth_paths
      |> Enum.with_index()
      |> Map.new(fn {path, index} ->
        next_path = Enum.at(depth_paths, index + 1)
        {path, reusable_source(if(next_path, do: [{"next", next_path}], else: []))}
      end)
      |> Map.put(@entry, entry_source([{"next", hd(depth_paths)}]))

    assert_error(depth_sources, "include.depth", Enum.at(depth_paths, 3))

    children = Enum.map(1..8, &".robine-ci/workflows/child-#{&1}.yml")
    leaf_a = ".robine-ci/workflows/leaf-a.yml"
    leaf_b = ".robine-ci/workflows/leaf-b.yml"

    count_sources =
      children
      |> Map.new(fn path ->
        {path, reusable_source([{"a", leaf_a}, {"b", leaf_b}])}
      end)
      |> Map.merge(%{
        @entry =>
          entry_source(
            Enum.with_index(children, 1)
            |> Enum.map(fn {path, i} -> {"c#{i}", path} end)
          ),
        leaf_a => reusable_source([]),
        leaf_b => reusable_source([])
      })

    assert_error(count_sources, "include.count", Enum.at(children, 5))
  end

  test "included jobs cannot depend on an entry or sibling job" do
    sources =
      update_in(valid_sources(), [@quality], fn source ->
        String.replace(source, "needs: security--scan", "needs: package")
      end)

    assert_error(sources, "job.need_unknown", @quality)
  end

  defp assert_error(sources, code, source_path) do
    assert {:error, diagnostics} =
             Workflows.resolve(
               %{entry_path: @entry, sources: sources},
               Dependencies.local_context()
             )

    assert Enum.any?(diagnostics, &(&1.code == code and &1.source_path == source_path)),
           inspect(diagnostics)
  end

  defp valid_sources do
    %{
      @entry => """
      version: 1
      name: CI
      on: {push: {branches: [main]}}
      includes:
        quality:
          path: #{@quality}
          inputs:
            runtime: "3.22"
      jobs:
        package:
          image: alpine:3.22
          needs: quality--test
          steps:
            - run: echo package
      """,
      @quality => """
      version: 1
      name: Quality
      on:
        workflow_call:
          inputs:
            runtime:
              type: choice
              required: true
              options: ["3.21", "3.22"]
      includes:
        security:
          path: #{@security}
          inputs:
            strict: true
      jobs:
        test:
          image: alpine:3.22
          needs: security--scan
          env:
            EXISTING: safe
          steps:
            - run: echo test
      """,
      @security => """
      version: 1
      name: Security
      on:
        workflow_call:
          inputs:
            strict:
              type: boolean
              required: true
      jobs:
        scan:
          image: alpine:3.22
          steps:
            - run: echo scan
      """
    }
  end

  defp entry_source(includes) do
    """
    version: 1
    name: Entry
    on: {push: {}}
    #{render_includes(includes)}
    jobs: {}
    """
  end

  defp reusable_source(includes) do
    """
    version: 1
    name: Reusable
    on: {workflow_call: {}}
    #{render_includes(includes)}
    jobs:
      test:
        image: alpine:3.22
        steps: [{run: "true"}]
    """
  end

  defp render_includes([]), do: ""

  defp render_includes(includes) do
    definitions =
      Enum.map_join(includes, "\n", fn {alias_name, path} ->
        "  #{alias_name}:\n    path: #{path}"
      end)

    "includes:\n#{definitions}"
  end
end
