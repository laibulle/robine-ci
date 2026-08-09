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
        runs-on: [docker, gpu]
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
    assert result.workflow.jobs["build"].runs_on == ["docker"]
    assert result.workflow.jobs["test"].runs_on == ["docker", "gpu"]
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

  test "rejects malformed runner labels at their exact position" do
    invalid =
      document(%{
        "test" => %{
          "image" => "alpine",
          "runs-on" => ["docker", "GPU Large"],
          "steps" => [%{"run" => "true"}]
        }
      })

    assert {:error, [%{code: "job.runs_on", path: ["jobs", "test", "runs-on", 1]}]} =
             Validator.validate(invalid)
  end

  test "normalizes bounded service definitions and declared secret mappings" do
    yaml = """
    version: 1
    name: Services
    on: {push: {}}
    jobs:
      test:
        image: alpine:3.22
        secrets: [TEST_DB_PASSWORD]
        services:
          postgres:
            image: postgres:18-alpine
            user: postgres
            env: {POSTGRES_DB: app_test}
            secret-env: {POSTGRES_PASSWORD: TEST_DB_PASSWORD}
            command: [postgres, -c, max_connections=50]
            readiness: {tcp: 5432, timeout: 45s}
        steps: [{run: "true"}]
    """

    assert {:ok, workflow, _warnings} = validate(yaml)
    service = workflow.jobs["test"].services["postgres"]
    assert service.id == "postgres"
    assert service.user == "postgres"
    assert service.secret_env == %{"POSTGRES_PASSWORD" => "TEST_DB_PASSWORD"}
    assert service.command == ["postgres", "-c", "max_connections=50"]
    assert service.readiness == %{tcp: 5432, timeout_ms: 45_000}
  end

  test "reports stable source-located service diagnostics" do
    cases = [
      {"Bad Name", "{image: postgres:18}", "service.id"},
      {"postgres", "{image: postgres:18, surprise: true}", "workflow.unknown_key"},
      {"postgres", "{image: postgres:18, env: {bad-name: value}}", "service.env"},
      {"postgres", "{image: postgres:18, secret-env: {PASSWORD: UNDECLARED}}",
       "service.secret_env"},
      {"postgres",
       "{image: postgres:18, env: {PASSWORD: literal}, secret-env: {PASSWORD: DECLARED}}",
       "service.secret_env"},
      {"postgres", "{image: postgres:18, readiness: {tcp: 70000}}", "service.readiness"}
    ]

    for {service_id, definition, code} <- cases do
      yaml = """
      version: 1
      name: Invalid service
      on: {push: {}}
      jobs:
        test:
          image: alpine:3.22
          secrets: [DECLARED]
          services:
            #{inspect(service_id)}: #{definition}
          steps: [{run: "true"}]
      """

      assert {:error, diagnostics} =
               Workflows.validate(%{source: yaml, path: "services.yml"}, context())

      assert Enum.any?(diagnostics, &(&1.code == code and is_integer(&1.line))),
             "expected source-located #{code}, got #{inspect(diagnostics)}"
    end
  end

  test "allows only the official attempt-scoped Docker-in-Docker service to be privileged" do
    valid = """
    version: 1
    name: DinD
    on: {push: {}}
    jobs:
      test:
        image: elixir:1.20
        services:
          docker:
            image: docker:28-dind-rootless
            privileged: true
            readiness: {tcp: 2375, timeout: 60s}
        steps: [{run: docker info}]
    """

    assert {:ok, workflow, _warnings} = validate(valid)
    assert workflow.jobs["test"].services["docker"].privileged

    for {service_id, image} <- [
          {"postgres", "docker:28-dind-rootless"},
          {"docker", "attacker.example/dind:latest"},
          {"docker", "postgres:18-alpine"}
        ] do
      invalid =
        valid
        |> String.replace("      docker:", "      #{service_id}:")
        |> String.replace("docker:28-dind-rootless", image)

      assert {:error, diagnostics} = validate(invalid)
      assert Enum.any?(diagnostics, &(&1.code == "service.privileged"))
    end
  end

  test "normalizes fixed job and step conditions" do
    yaml = """
    version: 1
    name: Conditions
    on: {push: {}}
    jobs:
      build:
        image: alpine:3.22
        steps:
          - run: make test
          - if: failure
            run: collect-diagnostics
          - if: always
            run: cleanup
      report:
        image: alpine:3.22
        needs: build
        if: failure
        steps: [{run: report}]
    """

    assert {:ok, workflow, _warnings} = validate(yaml)
    assert workflow.jobs["build"].condition == :success
    assert workflow.jobs["report"].condition == :failure

    assert Enum.map(workflow.jobs["build"].steps, & &1.condition) == [
             :success,
             :failure,
             :always
           ]
  end

  test "expands bounded matrices with deterministic keys, images, environment, and fan-in" do
    yaml = """
    version: 1
    name: Matrix
    on: {push: {}}
    jobs:
      test:
        strategy:
          matrix:
            otp: ["27", "28"]
            elixir: ["1.18", "1.19"]
        image: "elixir:${{ matrix.elixir }}-otp-${{ matrix.otp }}"
        services:
          database:
            image: "postgres:${{ matrix.otp }}-alpine"
        steps:
          - run: |
              printf '%s' "$ROBINE_MATRIX_ELIXIR:$ROBINE_MATRIX_OTP"
      summarize:
        image: alpine:3.22
        needs: test
        if: always
        steps: [{run: summarize}]
    """

    assert {:ok, workflow, _warnings} = validate(yaml)

    variants = [
      "test[elixir=1.18,otp=27]",
      "test[elixir=1.18,otp=28]",
      "test[elixir=1.19,otp=27]",
      "test[elixir=1.19,otp=28]"
    ]

    assert workflow.order == variants ++ ["summarize"]
    assert workflow.jobs["summarize"].needs == variants

    first = workflow.jobs[hd(variants)]
    assert first.base_id == "test"
    assert first.matrix_values == %{"elixir" => "1.18", "otp" => "27"}
    assert first.image == "elixir:1.18-otp-27"
    assert first.services["database"].image == "postgres:27-alpine"
    assert first.env["ROBINE_MATRIX_ELIXIR"] == "1.18"
    assert first.env["ROBINE_MATRIX_OTP"] == "27"
  end

  test "rejects invalid matrix contracts with stable source-located diagnostics" do
    cases = [
      {"matrix: {Bad-Axis: [one]}", "matrix.axis"},
      {"matrix: {otp: []}", "matrix.values"},
      {"matrix: {otp: [one, one]}", "matrix.value_duplicate"},
      {"matrix: {otp: [one, 'bad value']}", "matrix.value"},
      {"matrix: {a: [a, b, c, d, e, f, g, h], b: [a, b, c, d, e]}", "matrix.limit_variants"}
    ]

    for {matrix, code} <- cases do
      yaml = """
      version: 1
      name: Invalid matrix
      on: {push: {}}
      jobs:
        test:
          image: alpine:3.22
          strategy: {#{matrix}}
          steps: [{run: "true"}]
      """

      assert {:error, diagnostics} =
               Workflows.validate(%{source: yaml, path: "matrix.yml"}, context())

      assert Enum.any?(diagnostics, &(&1.code == code and is_integer(&1.line))),
             "expected #{code}, got #{inspect(diagnostics)}"
    end
  end

  test "rejects matrix image tokens, environment collisions, and ambiguous artifacts" do
    invalid_token = """
    version: 1
    name: Invalid token
    on: {push: {}}
    jobs:
      test:
        strategy: {matrix: {otp: ["27"]}}
        image: elixir:${{ matrix.missing }}
        steps: [{run: "true"}]
    """

    assert {:error, [%{code: "matrix.interpolation", line: 7}]} = validate(invalid_token)

    collision = """
    version: 1
    name: Collision
    on: {push: {}}
    jobs:
      test:
        strategy: {matrix: {otp: ["27"]}}
        env: {ROBINE_MATRIX_OTP: explicit}
        image: alpine
        steps: [{run: "true"}]
    """

    assert {:error, [%{code: "matrix.env_collision"}]} = validate(collision)

    ambiguous = """
    version: 1
    name: Ambiguous artifact
    on: {push: {}}
    jobs:
      build:
        strategy: {matrix: {otp: ["27", "28"]}}
        image: alpine
        steps: [{uses: artifacts/upload, with: {name: report, paths: [report]}}]
      consume:
        image: alpine
        needs: build
        steps: [{uses: artifacts/download, with: {name: report, from: build}}]
    """

    assert {:error, [%{code: "matrix.artifact_ambiguous"}]} = validate(ambiguous)
  end

  test "enforces configured job and step limits after matrix expansion" do
    matrix_job = %{
      "image" => "alpine",
      "strategy" => %{"matrix" => %{"variant" => ["one", "two"]}},
      "steps" => [%{"run" => "true"}]
    }

    limits = [max_jobs: 1, max_steps_per_job: 2, max_total_steps: 10, max_graph_depth: 2]

    assert {:error, [%{code: "workflow.limit_jobs"}]} =
             Validator.validate(document(%{"test" => matrix_job}), limits)

    limits = Keyword.merge(limits, max_jobs: 2, max_total_steps: 1)

    assert {:error, [%{code: "workflow.limit_total_steps"}]} =
             Validator.validate(document(%{"test" => matrix_job}), limits)
  end

  test "rejects generated matrix keys that exceed durable persistence bounds" do
    long_value = String.duplicate("v", 64)

    axes =
      for axis <- [
            "first_axis_name_is_long",
            "second_axis_name_long",
            "third_axis_name_is_long",
            "fourth_axis_name_long"
          ],
          into: %{},
          do: {axis, [long_value]}

    job = %{
      "image" => "alpine",
      "strategy" => %{"matrix" => axes},
      "steps" => [%{"run" => "true"}]
    }

    assert {:error, [%{code: "matrix.generated_id"}]} =
             Validator.validate(document(%{"long_matrix_job" => job}))
  end

  test "reports post-expansion limits at the workflow jobs source location" do
    matrix_job = fn id ->
      """
        #{id}:
          image: alpine
          strategy:
            matrix:
              a: [a, b, c]
              b: [a, b, c]
              c: [a, b, c]
          steps: [{run: "true"}]
      """
    end

    source = """
    version: 1
    name: Too many expanded jobs
    on: {push: {}}
    jobs:
    #{matrix_job.("first")}#{matrix_job.("second")}#{matrix_job.("third")}
    """

    assert {:error, [%{code: "workflow.limit_jobs", line: 4, column: 1}]} =
             Workflows.validate(%{source: source, path: "expanded-limit.yml"}, context())
  end

  test "emits bounded expansion measurements without axes or values as labels" do
    handler = "matrix-expansion-#{System.unique_integer([:positive])}"
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:robine, :workflow, :expansion],
        fn event, measurements, metadata, _config ->
          send(owner, {:matrix_expansion, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    source = """
    version: 1
    name: Matrix telemetry
    on: {push: {}}
    jobs:
      test:
        image: alpine
        strategy: {matrix: {version: ["one", "two"]}}
        steps: [{run: "true"}]
    """

    assert {:ok, _validated} =
             Workflows.validate(%{source: source, path: "matrix.yml"}, context())

    assert_receive {:matrix_expansion, [:robine, :workflow, :expansion],
                    %{expanded_jobs: 2, matrix_variants: 2}, %{}}
  end

  test "normalizes typed manual inputs and injects submitted values into matrix jobs" do
    source = """
    version: 1
    name: Manual matrix
    on:
      workflow_dispatch:
        inputs:
          environment:
            description: Deployment target
            type: choice
            required: true
            options: [staging, production]
          version:
            type: string
            required: true
          dry_run:
            type: boolean
            default: true
    jobs:
      test:
        strategy: {matrix: {runtime: ["one", "two"]}}
        image: alpine
        steps: [{run: "true"}]
    """

    assert {:ok, validated} =
             Workflows.validate(%{source: source, path: "manual.yml"}, context())

    definitions = validated.workflow.triggers["workflow_dispatch"]["inputs"]
    assert definitions["environment"].type == :choice
    assert definitions["environment"].options == ["staging", "production"]
    assert definitions["version"].required
    assert definitions["dry_run"].default == "true"

    assert {:ok, prepared} =
             Workflows.prepare_manual_run(%{
               validated_workflow: validated,
               inputs: %{"environment" => "production", "version" => "1.2.3"}
             })

    assert prepared.inputs == %{
             "dry_run" => "true",
             "environment" => "production",
             "version" => "1.2.3"
           }

    assert Enum.all?(prepared.workflow.jobs, fn {_id, job} ->
             job.env["ROBINE_INPUT_ENVIRONMENT"] == "production" and
               job.env["ROBINE_INPUT_VERSION"] == "1.2.3" and
               job.env["ROBINE_INPUT_DRY_RUN"] == "true"
           end)
  end

  test "rejects invalid manual definitions and reserved environment collisions at source" do
    cases = [
      {"type: number", "manual_input.type"},
      {"type: choice, options: [one]", "manual_input.options"},
      {"type: boolean, default: maybe", "manual_input.default"},
      {"type: string, required: yes", "manual_input.required"},
      {"type: string, options: [one, two]", "manual_input.options"}
    ]

    for {definition, code} <- cases do
      source = """
      version: 1
      name: Invalid manual input
      on:
        workflow_dispatch:
          inputs:
            target: {#{definition}}
      jobs:
        test: {image: alpine, steps: [{run: "true"}]}
      """

      assert {:error, diagnostics} =
               Workflows.validate(%{source: source, path: "manual.yml"}, context())

      assert Enum.any?(diagnostics, &(&1.code == code and is_integer(&1.line))),
             "expected #{code}, got #{inspect(diagnostics)}"
    end

    collision = """
    version: 1
    name: Collision
    on:
      workflow_dispatch:
        inputs:
          target: {type: string}
    jobs:
      test:
        image: alpine
        env: {ROBINE_INPUT_TARGET: explicit}
        steps: [{run: "true"}]
    """

    assert {:error, [%{code: "manual_input.env_collision", line: 10}]} =
             Workflows.validate(%{source: collision, path: "manual.yml"}, context())
  end

  test "manual input policy rejects missing, undeclared, invalid choice, and invalid boolean values" do
    source = """
    version: 1
    name: Manual policy
    on:
      workflow_dispatch:
        inputs:
          target: {type: choice, required: true, options: [one, two]}
          confirm: {type: boolean, required: true}
    jobs:
      test: {image: alpine, steps: [{run: "true"}]}
    """

    assert {:ok, validated} =
             Workflows.validate(%{source: source, path: "manual.yml"}, context())

    assert {:error, {:manual_input, "confirm", :required}} =
             Workflows.prepare_manual_run(%{
               validated_workflow: validated,
               inputs: %{"target" => "one"}
             })

    assert {:error, {:manual_inputs_undeclared, ["secret"]}} =
             Workflows.prepare_manual_run(%{
               validated_workflow: validated,
               inputs: %{"target" => "one", "confirm" => "true", "secret" => "value"}
             })

    assert {:error, {:manual_input, "confirm", :invalid_boolean}} =
             Workflows.prepare_manual_run(%{
               validated_workflow: validated,
               inputs: %{"target" => "one", "confirm" => "yes"}
             })

    assert {:error, {:manual_input, "target", :invalid_choice}} =
             Workflows.prepare_manual_run(%{
               validated_workflow: validated,
               inputs: %{"target" => "three", "confirm" => "true"}
             })
  end

  test "rejects unknown conditions and independent failure jobs at exact sources" do
    invalid_value = """
    version: 1
    name: Invalid condition
    on: {push: {}}
    jobs:
      test:
        image: alpine:3.22
        if: ${{ arbitrary.code }}
        steps:
          - if: maybe
            run: true
    """

    assert {:error, diagnostics} =
             Workflows.validate(%{source: invalid_value, path: "conditions.yml"}, context())

    assert Enum.any?(diagnostics, &(&1.code == "condition.value" and &1.line == 7))

    independent_failure = """
    version: 1
    name: Invalid failure job
    on: {push: {}}
    jobs:
      report:
        image: alpine:3.22
        if: failure
        steps: [{run: report}]
    """

    assert {:error, [%{code: "job.condition_dependencies", line: 7}]} =
             Workflows.validate(
               %{source: independent_failure, path: "conditions.yml"},
               context()
             )
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
