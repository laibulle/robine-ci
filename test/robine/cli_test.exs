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

  test "creates a valid Node workflow without executing project code", %{directory: directory} do
    File.write!(Path.join(directory, "package.json"), ~s({"scripts":{"test":"exit 99"}}))

    assert {0, _created} = CLI.run(["init", "--yes"], directory)
    assert {0, _valid} = CLI.run(["validate"], directory)

    workflow = File.read!(Path.join(directory, ".robine-ci/workflows/ci.yml"))
    assert workflow =~ "node:24-alpine"
    assert workflow =~ "npm ci"
    assert workflow =~ "npm test"
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

  test "returns stable usage and prerequisite exit classes", %{directory: directory} do
    assert {64, usage} = CLI.run(["unknown"], directory)
    assert usage =~ "Usage:"

    assert {3, missing} = CLI.run(["validate", "missing.yml"], directory)
    assert missing =~ "Create it with `robine init`"
  end

  test "requires local secret files to be regular, repository-local, and ignored", %{
    directory: directory
  } do
    initialize_git(directory)
    File.write!(Path.join(directory, ".gitignore"), ".robine.env\n")
    File.write!(Path.join(directory, ".robine.env"), "TOKEN=local-secret-value\n")

    assert {:ok, %{"TOKEN" => "local-secret-value"}} =
             Robine.Adapters.CLI.LocalSecretFile.load(".robine.env", directory)

    File.write!(Path.join(directory, "visible.env"), "TOKEN=local-secret-value\n")

    assert {:error, :local_secret_file_not_ignored} =
             Robine.Adapters.CLI.LocalSecretFile.load("visible.env", directory)

    assert {:error, {:invalid_local_secret_file, 2}} =
             Robine.Adapters.CLI.LocalSecretFile.parse(
               "TOKEN=local-secret-value\nTOKEN=duplicate-value"
             )
  end

  @tag :docker
  test "returns the stable job-failure class for a reproduced command failure", %{
    directory: directory
  } do
    workflow = """
    version: 1
    name: Failure
    on: {push: {}}
    jobs:
      fail:
        image: postgres:18-alpine
        steps:
          - run: exit 7
    """

    path = Path.join(directory, ".robine-ci/workflows/ci.yml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, workflow)

    assert {5, output} = CLI.run(["run", "fail"], directory)
    assert output =~ "Job failed: command_failed"
  end

  @tag :docker
  test "injects only declared values from an ignored local secret file and redacts output", %{
    directory: directory
  } do
    initialize_git(directory)
    File.write!(Path.join(directory, ".gitignore"), ".robine.env\n")
    secret = "local-secret-fixture"

    File.write!(
      Path.join(directory, ".robine.env"),
      "LOCAL_TOKEN=#{secret}\nUNUSED_TOKEN=unused-secret\n"
    )

    workflow = """
    version: 1
    name: Local secrets
    on: {push: {}}
    jobs:
      verify:
        image: postgres:18-alpine
        secrets: [LOCAL_TOKEN]
        steps:
          - run: test -z "$UNUSED_TOKEN"; printf '%s' "$LOCAL_TOKEN"
    """

    path = Path.join(directory, ".robine-ci/workflows/ci.yml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, workflow)

    assert {0, output} = CLI.run(["run", "verify", "--env-file", ".robine.env"], directory)
    assert output =~ "[REDACTED]"
    refute output =~ secret
    refute output =~ "unused-secret"

    File.write!(Path.join(directory, ".robine.env"), "OTHER_TOKEN=other-secret\n")
    assert {2, missing} = CLI.run(["run", "verify", "--env-file", ".robine.env"], directory)
    assert missing =~ "missing required names: LOCAL_TOKEN"
    refute missing =~ "other-secret"
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

  defp initialize_git(directory) do
    assert {_output, 0} = System.cmd("git", ["init", "--quiet", directory])
  end
end
