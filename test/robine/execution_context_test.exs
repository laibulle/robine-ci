defmodule Robine.ExecutionContextTest do
  use ExUnit.Case, async: true

  alias Robine.ExecutionContext

  test "standalone contexts retain role compatibility in the reserved tenant" do
    context = ExecutionContext.new(%{id: "user-1", role: :maintainer}, "request-1", %{})

    assert context.tenant_id == "standalone"
    assert ExecutionContext.capable?(context, :ci_read)
    assert ExecutionContext.capable?(context, :ci_run)
    refute ExecutionContext.capable?(context, :ci_manage)
  end

  test "embedded contexts require tenant, correlation, actor and capabilities" do
    actor = %{id: "workspace-user-1", role: :member}

    assert {:ok, context} =
             ExecutionContext.embedded(actor, "workspace-1", [:ci_read], "request-1")

    assert context.tenant_id == "workspace-1"
    assert context.actor.role == :viewer
    assert ExecutionContext.capable?(context, :ci_read)

    assert {:error, :invalid_execution_context} =
             ExecutionContext.embedded(actor, "", [:ci_read], "request-1")

    assert {:error, :invalid_execution_context} =
             ExecutionContext.embedded(actor, "workspace-1", [], "request-1")

    assert {:error, :invalid_execution_context} =
             ExecutionContext.embedded(actor, "workspace-1", [:unknown], "request-1")
  end

  test "embedded capabilities, rather than host role names, drive legacy authorization" do
    host_owner = %{id: "workspace-owner", role: :owner}

    assert {:ok, manager} =
             ExecutionContext.embedded(host_owner, "workspace-1", [:ci_manage], "request-1")

    assert manager.actor.role == :administrator

    assert {:ok, runner} =
             ExecutionContext.embedded(host_owner, "workspace-1", [:ci_runner], "request-2")

    assert runner.actor.role == :runner

    assert {:error, :invalid_execution_context} =
             ExecutionContext.embedded(
               host_owner,
               "workspace-1",
               [:ci_runner, :ci_read],
               "request-3"
             )
  end
end
