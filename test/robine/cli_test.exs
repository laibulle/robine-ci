defmodule Robine.CLITest do
  use ExUnit.Case, async: false

  alias Robine.Adapters.CLI

  setup do
    directory = Path.join(System.tmp_dir!(), "robine-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "previews, creates, validates, and protects an Elixir workflow", %{directory: directory} do
    File.write!(Path.join(directory, "mix.exs"), "defmodule Example.MixProject do end")

    assert {0, preview} = CLI.run(["init"], directory)
    assert preview =~ "Would create"
    refute File.exists?(Path.join(directory, ".robine-ci/workflows/ci.yml"))

    assert {0, created} = CLI.run(["init", "--yes"], directory)
    assert created =~ "Created"
    assert {0, valid} = CLI.run(["validate"], directory)
    assert valid =~ "Valid workflow"
    assert {4, protected} = CLI.run(["init", "--yes"], directory)
    assert protected =~ "Refusing to overwrite"
  end

  test "returns stable JSON diagnostics", %{directory: directory} do
    path = Path.join(directory, "broken.yml")
    File.write!(path, "jobs: [")

    assert {2, output} = CLI.run(["validate", path, "--format", "json"], directory)

    assert %{"valid" => false, "diagnostics" => [%{"code" => "yaml.syntax"}]} =
             Jason.decode!(output)
  end

  test "reports its version without external access", %{directory: directory} do
    assert {0, "robine 0.1.0"} = CLI.run(["version"], directory)
  end

  @tag :docker
  test "runs cache and artifact built-ins locally without a server", %{directory: directory} do
    workflow = """
    version: 1
    name: Local data
    on: {push: {}}
    jobs:
      build:
        image: postgres:18-alpine
        steps:
          - uses: checkout
          - run: mkdir -p deps reports; printf cached > deps/value; printf report > reports/value
          - uses: cache/save
            with:
              key: deps-${{ checksum('mix.lock') }}
              paths: [deps]
          - run: rm -rf deps
          - uses: cache/restore
            with:
              key: deps-${{ checksum('mix.lock') }}
              paths: [deps]
          - uses: artifacts/upload
            with:
              name: reports
              paths: [reports]
          - run: test "$(cat deps/value)" = cached
      consume:
        image: postgres:18-alpine
        needs: build
        steps:
          - uses: checkout
          - uses: artifacts/download
            with:
              name: reports
              from: build
              path: imported
          - run: printf 'received:%s' "$(cat imported/reports/value)"
    """

    path = Path.join(directory, ".robine-ci/workflows/ci.yml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, workflow)
    File.write!(Path.join(directory, "mix.lock"), "exact-lock")

    assert {0, output} = CLI.run(["run"], directory)
    assert output =~ "Published cache"
    assert output =~ "Published artifact reports"
    assert output =~ "received:report"
  end
end
