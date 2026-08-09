defmodule Robine.Execution.UseCases.BuildLocalPlanTest do
  use ExUnit.Case, async: true

  alias Robine.Execution
  alias Robine.ExecutionContext
  alias Robine.Workflows.Contracts.ValidatedWorkflow
  alias Robine.Workflows.Domain.{Job, Service, Step, Workflow}

  test "selects dependencies in graph order and converts jobs to local specifications" do
    workflow = workflow()
    context = ExecutionContext.new(%{id: "developer", role: :maintainer}, "local-plan", %{})

    assert {:ok, plan} =
             Execution.build_local_plan(
               %{
                 validated_workflow: validated(workflow),
                 source_path: "/tmp/project",
                 job_id: "test",
                 step: nil
               },
               context
             )

    assert plan.selected_jobs == ["build", "test"]
    assert Enum.map(plan.specifications, & &1.metadata["job_id"]) == ["build", "test"]
    assert Enum.all?(plan.specifications, &(&1.source_path == "/tmp/project"))
    assert Enum.map(plan.specifications, & &1.metadata["needs"]) == [[], ["build"]]
    assert Enum.all?(plan.specifications, &(&1.metadata["condition"] == :success))
    assert [%{kind: :run, value: "mix compile"}] = hd(plan.specifications).steps
  end

  test "evaluates fixed local job conditions as a pure facade operation" do
    assert {:ok, :run} =
             Execution.evaluate_job_condition(%{
               condition: :failure,
               dependency_statuses: [:succeeded, :failed]
             })

    assert {:ok, :skip} =
             Execution.evaluate_job_condition(%{
               condition: :success,
               dependency_statuses: [:succeeded, :skipped]
             })

    assert {:ok, :run} =
             Execution.evaluate_job_condition(%{
               condition: :always,
               dependency_statuses: [:succeeded, :skipped]
             })

    assert {:ok, :skip} =
             Execution.evaluate_job_condition(%{
               condition: :always,
               dependency_statuses: [:cancelled]
             })
  end

  test "selects every matrix variant by base ID or one exact generated key" do
    document = %{
      "version" => 1,
      "name" => "Matrix",
      "on" => %{"push" => %{}},
      "jobs" => %{
        "test" => %{
          "image" => "alpine:${{ matrix.version }}",
          "strategy" => %{"matrix" => %{"version" => ["3.21", "3.22"]}},
          "steps" => [%{"run" => "true"}]
        }
      }
    }

    assert {:ok, matrix_workflow, _warnings} =
             Robine.Workflows.Domain.Validator.validate(document)

    context = ExecutionContext.new(%{id: "developer", role: :maintainer}, "matrix-plan", %{})

    assert {:ok, grouped} =
             Execution.build_local_plan(
               %{
                 validated_workflow: validated(matrix_workflow),
                 source_path: "/tmp/project",
                 job_id: "test"
               },
               context
             )

    assert Enum.map(grouped.specifications, & &1.metadata["job_id"]) == [
             "test[version=3.21]",
             "test[version=3.22]"
           ]

    assert Enum.map(grouped.specifications, & &1.metadata["matrix_values"]) == [
             %{"version" => "3.21"},
             %{"version" => "3.22"}
           ]

    assert {:ok, exact} =
             Execution.build_local_plan(
               %{
                 validated_workflow: validated(matrix_workflow),
                 source_path: "/tmp/project",
                 job_id: "test[version=3.22]"
               },
               context
             )

    assert [%{image: "alpine:3.22"}] = exact.specifications
  end

  test "supports no-deps and one selected step" do
    context = ExecutionContext.new(%{id: "developer", role: :maintainer}, "local-plan", %{})

    assert {:ok, plan} =
             Execution.build_local_plan(
               %{
                 validated_workflow: validated(workflow()),
                 source_path: "/tmp/project",
                 job_id: "test",
                 no_deps: true,
                 step: "Test"
               },
               context
             )

    assert plan.selected_jobs == ["test"]
    assert [%{steps: [%{name: "Test", value: "mix test"}]}] = plan.specifications
  end

  test "injects only explicitly declared local secrets and rejects missing declarations" do
    context = ExecutionContext.new(%{id: "developer", role: :maintainer}, "local-secrets", %{})

    assert {:ok, plan} =
             Execution.build_local_plan(
               %{
                 validated_workflow: validated(workflow()),
                 source_path: "/tmp/project",
                 job_id: "test",
                 step: nil,
                 local_secret_file: true,
                 local_secrets: %{"TOKEN" => "local-secret", "UNUSED" => "unused-secret"}
               },
               context
             )

    assert [%{secrets: %{}}, %{secrets: %{"TOKEN" => "local-secret"}}] = plan.specifications
    assert plan.local_secret_count == 1

    assert {:error, {:local_secrets_missing, ["TOKEN"]}} =
             Execution.build_local_plan(
               %{
                 validated_workflow: validated(workflow()),
                 source_path: "/tmp/project",
                 job_id: "test",
                 step: nil,
                 local_secret_file: true,
                 local_secrets: %{}
               },
               context
             )
  end

  test "resolves declared service secrets into local execution only" do
    context = ExecutionContext.new(%{id: "developer", role: :maintainer}, "local-services", %{})
    base = workflow()
    test_job = base.jobs["test"]

    service = %Service{
      id: "postgres",
      image: "postgres:18-alpine",
      secret_env: %{"POSTGRES_PASSWORD" => "TOKEN"},
      readiness: %{tcp: 5432, timeout_ms: 30_000}
    }

    workflow = put_in(base.jobs["test"], %{test_job | services: %{"postgres" => service}})

    assert {:ok, %{specifications: [_build, test]}} =
             Execution.build_local_plan(
               %{
                 validated_workflow: validated(workflow),
                 source_path: "/tmp/project",
                 job_id: "test",
                 local_secret_file: true,
                 local_secrets: %{"TOKEN" => "local-service-secret"}
               },
               context
             )

    assert [resolved] = test.services
    assert resolved.secret_env == %{"POSTGRES_PASSWORD" => "local-service-secret"}
    refute inspect(test) =~ "local-service-secret"
  end

  defp validated(workflow),
    do: %ValidatedWorkflow{
      path: "/tmp/project/.robine-ci/workflows/ci.yml",
      workflow: workflow,
      warnings: []
    }

  defp workflow do
    %Workflow{
      version: 1,
      name: "CI",
      triggers: %{},
      order: ["build", "test"],
      jobs: %{
        "build" => %Job{
          id: "build",
          image: "elixir:1.18",
          needs: [],
          steps: [
            %Step{name: "Checkout", kind: :builtin, value: "checkout"},
            %Step{name: "Compile", kind: :run, value: "mix compile"}
          ]
        },
        "test" => %Job{
          id: "test",
          image: "elixir:1.18",
          needs: ["build"],
          secrets: ["TOKEN"],
          steps: [%Step{name: "Test", kind: :run, value: "mix test"}]
        }
      }
    }
  end
end
