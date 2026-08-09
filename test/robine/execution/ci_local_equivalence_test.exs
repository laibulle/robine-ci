defmodule Robine.Execution.CiLocalEquivalenceTest do
  use Robine.DataCase, async: false

  alias Robine.{Execution, Pipelines, Workflows}
  alias Robine.Runtime.Dependencies

  @fixture Path.expand("../../fixtures/equivalence/contract.yml", __DIR__)
  @success_fixture Path.expand("../../fixtures/equivalence/success.yml", __DIR__)

  @tag :docker
  test "CI and local paths preserve command, environment, workspace, image, timeout, and exit" do
    source = File.read!(@fixture)
    source_path = Path.dirname(@fixture)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "equivalence")

    assert {:ok, validated} =
             Workflows.validate(%{source: source, path: @fixture}, context)

    assert {:ok, local_plan} =
             Execution.build_local_plan(
               %{
                 validated_workflow: validated,
                 source_path: source_path,
                 job_id: "verify",
                 step: nil
               },
               context
             )

    assert [local] = local_plan.specifications

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: validated.workflow.name,
                 commit_sha: String.duplicate("e", 40),
                 jobs: validated.workflow.jobs,
                 workflow_revision: %{path: @fixture, source: source}
               },
               context
             )

    assert {:ok, _queued} = Pipelines.queue_pipeline(%{pipeline_id: pipeline.id}, context)
    assert {:ok, attempt} = Pipelines.claim_next_job(%{}, context)

    assert {:ok, persisted} =
             Pipelines.job_execution(%{idempotency_token: attempt.idempotency_token}, context)

    assert {:ok, ci} =
             Execution.build_ci_specification(
               %{persisted: persisted, source_path: source_path},
               context
             )

    assert contract_projection(ci) == contract_projection(local)
    assert ci.timeout_ms == 30_000

    assert {:ok, ci_result} = Execution.run_job(%{specification: ci}, context)
    assert {:ok, local_result} = Execution.run_job(%{specification: local}, context)

    assert result_projection(ci_result) == result_projection(local_result)

    assert result_projection(ci_result) == %{
             status: :failed,
             reason: :command_failed,
             steps: [
               %{
                 status: :failed,
                 exit_code: 7,
                 output: "env=identical-environment workspace=/workspace"
               }
             ]
           }
  end

  @tag :docker
  test "successful commands have the same normalized contract and terminal result" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "equivalence-success")
    {ci, local} = specifications(@success_fixture, context)

    assert contract_projection(ci) == contract_projection(local)
    assert ci.timeout_ms == 45_000

    assert {:ok, ci_result} = Execution.run_job(%{specification: ci}, context)
    assert {:ok, local_result} = Execution.run_job(%{specification: local}, context)
    assert result_projection(ci_result) == result_projection(local_result)

    assert result_projection(ci_result) == %{
             status: :succeeded,
             reason: nil,
             steps: [
               %{
                 status: :succeeded,
                 exit_code: 0,
                 output: "env=successful-environment workspace=/workspace"
               }
             ]
           }
  end

  defp specifications(fixture, context) do
    source = File.read!(fixture)
    source_path = Path.dirname(fixture)
    assert {:ok, validated} = Workflows.validate(%{source: source, path: fixture}, context)

    assert {:ok, %{specifications: [local]}} =
             Execution.build_local_plan(
               %{
                 validated_workflow: validated,
                 source_path: source_path,
                 job_id: "verify",
                 step: nil
               },
               context
             )

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: validated.workflow.name,
                 commit_sha: String.duplicate("f", 40),
                 jobs: validated.workflow.jobs,
                 workflow_revision: %{path: fixture, source: source}
               },
               context
             )

    assert {:ok, _queued} = Pipelines.queue_pipeline(%{pipeline_id: pipeline.id}, context)
    assert {:ok, attempt} = Pipelines.claim_next_job(%{}, context)

    assert {:ok, persisted} =
             Pipelines.job_execution(%{idempotency_token: attempt.idempotency_token}, context)

    assert {:ok, ci} =
             Execution.build_ci_specification(
               %{persisted: persisted, source_path: source_path},
               context
             )

    {ci, local}
  end

  defp contract_projection(specification) do
    %{
      image: specification.image,
      workspace: specification.workspace,
      shell: specification.shell,
      timeout_ms: specification.timeout_ms,
      env: specification.env,
      steps:
        Enum.map(
          specification.steps,
          &Map.take(Map.from_struct(&1), [:name, :kind, :value, :with])
        )
    }
  end

  defp result_projection(result) do
    %{
      status: result.status,
      reason: result.reason,
      steps:
        Enum.map(result.steps, &Map.take(Map.from_struct(&1), [:status, :exit_code, :output]))
    }
  end
end
