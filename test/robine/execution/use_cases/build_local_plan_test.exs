defmodule Robine.Execution.UseCases.BuildLocalPlanTest do
  use ExUnit.Case, async: true

  alias Robine.Execution
  alias Robine.ExecutionContext
  alias Robine.Workflows.Contracts.ValidatedWorkflow
  alias Robine.Workflows.Domain.{Job, Step, Workflow}

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
    assert [%{kind: :run, value: "mix compile"}] = hd(plan.specifications).steps
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
