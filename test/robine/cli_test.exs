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

  test "validation displays deterministic expanded matrix job keys", %{directory: directory} do
    path = Path.join(directory, "matrix.yml")

    File.write!(
      path,
      """
      version: 1
      name: Matrix validation
      on: {push: {}}
      jobs:
        test:
          strategy: {matrix: {version: ["3.21", "3.22"]}}
          image: "alpine:${{ matrix.version }}"
          steps: [{run: "true"}]
      """
    )

    assert {0, human} = CLI.run(["validate", path], directory)
    assert human =~ "Expanded jobs (2)"
    assert human =~ "test[version=3.21]"
    assert human =~ "test[version=3.22]"

    assert {0, json} = CLI.run(["validate", path, "--format", "json"], directory)

    assert Jason.decode!(json)["jobs"] == [
             "test[version=3.21]",
             "test[version=3.22]"
           ]
  end

  test "validation discovers and composes repository-local reusable workflows", %{
    directory: directory
  } do
    workflow_directory = Path.join(directory, ".robine-ci/workflows")
    File.mkdir_p!(workflow_directory)

    File.write!(Path.join(workflow_directory, "ci.yml"), reusable_entry())
    File.write!(Path.join(workflow_directory, "quality.yml"), reusable_quality())

    assert {0, human} = CLI.run(["validate"], directory)
    assert human =~ "Expanded jobs (2)"
    assert human =~ "quality--test"
    assert human =~ "package"

    File.write!(Path.join(workflow_directory, "quality.yml"), "jobs: [")

    assert {2, invalid} = CLI.run(["validate"], directory)
    assert invalid =~ ".robine-ci/workflows/quality.yml"
    assert invalid =~ "yaml.syntax"
  end

  test "reports its version without external access", %{directory: directory} do
    assert {0, "robine 0.3.0-alpha9"} = CLI.run(["version"], directory)
  end

  test "returns stable usage and prerequisite exit classes", %{directory: directory} do
    assert {64, usage} = CLI.run(["unknown"], directory)
    assert usage =~ "Usage:"

    assert {3, missing} = CLI.run(["validate", "missing.yml"], directory)
    assert missing =~ "Create it with `robine init`"
  end

  test "validates repeated manual inputs before local execution", %{directory: directory} do
    path = Path.join(directory, "manual.yml")

    File.write!(path, """
    version: 1
    name: Manual
    on:
      workflow_dispatch:
        inputs:
          environment: {type: choice, options: [staging, production], required: true}
    jobs:
      release:
        image: alpine:3.22
        steps: [{run: "true"}]
    """)

    assert {2, duplicate} =
             CLI.run(
               [
                 "run",
                 "release",
                 "--workflow",
                 path,
                 "--input",
                 "environment=staging",
                 "--input",
                 "environment=production"
               ],
               directory
             )

    assert duplicate =~ "supplied more than once"

    assert {2, choice} =
             CLI.run(
               ["run", "release", "--workflow", path, "--input", "environment=invalid"],
               directory
             )

    assert choice =~ "not an allowed choice"

    assert {2, undeclared} =
             CLI.run(
               ["run", "release", "--workflow", path, "--input", "target=production"],
               directory
             )

    assert undeclared =~ "Undeclared manual inputs: target"
  end

  @tag :docker
  test "injects declared manual inputs into local Docker execution", %{directory: directory} do
    path = Path.join(directory, "manual.yml")

    File.write!(path, """
    version: 1
    name: Manual local
    on:
      workflow_dispatch:
        inputs:
          environment: {type: choice, options: [staging, production], required: true}
          version: {type: string, required: true}
    jobs:
      release:
        image: alpine:3.22
        steps:
          - run: printf '%s:%s' "$ROBINE_INPUT_ENVIRONMENT" "$ROBINE_INPUT_VERSION"
    """)

    assert {0, output} =
             CLI.run(
               [
                 "run",
                 "release",
                 "--workflow",
                 path,
                 "--input",
                 "environment=production",
                 "--input",
                 "version=2.4.0"
               ],
               directory
             )

    assert output =~ "production:2.4.0"
  end

  @tag :docker
  test "executes a composed reusable job locally with normalized call inputs", %{
    directory: directory
  } do
    workflow_directory = Path.join(directory, ".robine-ci/workflows")
    File.mkdir_p!(workflow_directory)
    File.write!(Path.join(workflow_directory, "ci.yml"), reusable_entry())
    File.write!(Path.join(workflow_directory, "quality.yml"), reusable_quality())

    assert {0, output} = CLI.run(["run", "quality--test"], directory)
    assert output =~ "Running quality--test"
    assert output =~ "runtime:3.22"
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
  test "shows skipped and diagnostic steps while preserving the original local failure", %{
    directory: directory
  } do
    workflow = """
    version: 1
    name: Conditional failure
    on: {push: {}}
    jobs:
      test:
        image: alpine:3.22
        steps:
          - name: Primary
            run: printf primary; exit 7
          - name: Success only
            if: success
            run: echo must-not-run
          - name: Diagnostic
            if: failure
            run: printf diagnostic
          - name: Cleanup
            if: always
            run: printf cleanup
    """

    path = Path.join(directory, ".robine-ci/workflows/ci.yml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, workflow)

    assert {5, output} = CLI.run(["run", "test"], directory)
    assert output =~ "[failed] Primary"
    assert output =~ "[skipped] Success only"
    assert output =~ "[succeeded] Diagnostic"
    assert output =~ "[succeeded] Cleanup"
    assert output =~ "Job failed: command_failed"
    refute output =~ "must-not-run"
  end

  @tag :docker
  test "evaluates conditional jobs locally from dependency outcomes", %{directory: directory} do
    workflow = """
    version: 1
    name: Conditional jobs
    on: {push: {}}
    jobs:
      build:
        image: alpine:3.22
        steps:
          - run: printf build-failed; exit 4
      success-only:
        image: alpine:3.22
        needs: build
        if: success
        steps:
          - run: echo must-not-run
      reporter:
        image: alpine:3.22
        needs: build
        if: failure
        steps:
          - run: printf reporter-ran
      cleanup:
        image: alpine:3.22
        needs: success-only
        if: always
        steps:
          - run: printf cleanup-ran
    """

    path = Path.join(directory, ".robine-ci/workflows/ci.yml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, workflow)

    assert {5, output} = CLI.run(["run"], directory)
    assert output =~ "build-failed"
    assert output =~ "[skipped] success-only (if: success did not match dependency outcomes)"
    assert output =~ "reporter-ran"
    assert output =~ "cleanup-ran"
    refute output =~ "must-not-run"
  end

  @tag :docker
  test "runs every selected matrix variant locally with immutable matrix environment", %{
    directory: directory
  } do
    workflow = """
    version: 1
    name: Local matrix
    on: {push: {}}
    jobs:
      test:
        strategy:
          matrix:
            version: ["3.21", "3.22"]
        image: "alpine:${{ matrix.version }}"
        services:
          helper:
            image: "alpine:${{ matrix.version }}"
            command: [sleep, "30"]
        steps:
          - run: getent hosts helper; printf 'matrix=%s' "$ROBINE_MATRIX_VERSION"
    """

    path = Path.join(directory, ".robine-ci/workflows/ci.yml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, workflow)

    assert {0, output} = CLI.run(["run", "test"], directory)
    assert output =~ "Running test[version=3.21] with alpine:3.21"
    assert output =~ "matrix=3.21"
    assert output =~ "Running test[version=3.22] with alpine:3.22"
    assert output =~ "matrix=3.22"
    assert output =~ "Service helper: Service ready"

    assert {0, exact} = CLI.run(["run", "test[version=3.22]"], directory)
    assert exact =~ "Running test[version=3.22] with alpine:3.22"
    assert exact =~ "matrix=3.22"
    refute exact =~ "matrix=3.21"
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
  test "runs a PostgreSQL service locally with an ignored declared secret", %{
    directory: directory
  } do
    initialize_git(directory)
    File.write!(Path.join(directory, ".gitignore"), ".robine.env\n")
    secret = "local-postgres-secret"
    File.write!(Path.join(directory, ".robine.env"), "TEST_DB_PASSWORD=#{secret}\n")

    workflow = """
    version: 1
    name: Local services
    on: {push: {}}
    jobs:
      integration:
        image: postgres:18-alpine
        secrets: [TEST_DB_PASSWORD]
        services:
          postgres:
            image: postgres:18-alpine
            user: postgres
            env:
              POSTGRES_USER: robine
              POSTGRES_DB: app_test
            secret-env:
              POSTGRES_PASSWORD: TEST_DB_PASSWORD
            readiness: {tcp: 5432, timeout: 30s}
        steps:
          - run: PGPASSWORD="$TEST_DB_PASSWORD" psql -h postgres -U robine -d app_test -Atc 'select 42'
    """

    path = Path.join(directory, ".robine-ci/workflows/ci.yml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, workflow)

    assert {0, output} =
             CLI.run(["run", "integration", "--env-file", ".robine.env"], directory)

    assert output =~ "Service postgres"
    assert output =~ "42"
    refute output =~ secret
  end

  @tag :docker
  test "runs a pinned Redis service locally by service DNS", %{directory: directory} do
    redis =
      "redis@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241"

    workflow = """
    version: 1
    name: Local Redis
    on: {push: {}}
    jobs:
      integration:
        image: #{redis}
        services:
          redis:
            image: #{redis}
            user: redis
            readiness: {tcp: 6379, timeout: 15s}
        steps:
          - run: redis-cli -h redis ping
    """

    path = Path.join(directory, ".robine-ci/workflows/ci.yml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, workflow)

    assert {0, output} = CLI.run(["run", "integration"], directory)
    assert output =~ "Service redis: Service ready"
    assert output =~ "PONG"
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

  defp reusable_entry do
    """
    version: 1
    name: Reusable local
    on: {push: {}}
    includes:
      quality:
        path: .robine-ci/workflows/quality.yml
        inputs:
          runtime: "3.22"
    jobs:
      package:
        image: alpine:3.22
        needs: quality--test
        steps: [{run: "true"}]
    """
  end

  defp reusable_quality do
    """
    version: 1
    name: Shared quality
    on:
      workflow_call:
        inputs:
          runtime:
            type: choice
            required: true
            options: ["3.21", "3.22"]
    jobs:
      test:
        image: alpine:3.22
        steps:
          - run: printf 'runtime:%s' "$ROBINE_CALL_INPUT_RUNTIME"
    """
  end
end
