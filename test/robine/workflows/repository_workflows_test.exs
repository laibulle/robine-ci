defmodule Robine.Workflows.RepositoryWorkflowsTest do
  use ExUnit.Case, async: true

  alias Robine.ExecutionContext
  alias Robine.Workflows
  alias Robine.Workflows.Dependencies

  test "every workflow shipped by this repository satisfies the current contract" do
    context =
      ExecutionContext.new(%{id: "repository-workflow-test", role: :maintainer}, "test", %{
        workflows: %Dependencies{decoder: Robine.Adapters.Workflow.YamlDecoder}
      })

    workflows = Path.wildcard(".robine-ci/workflows/*.yml")
    assert workflows != []

    for path <- workflows do
      assert {:ok, _validated} =
               Workflows.validate(%{source: File.read!(path), path: path}, context),
             "#{path} must remain a valid Robine workflow"
    end
  end
end
