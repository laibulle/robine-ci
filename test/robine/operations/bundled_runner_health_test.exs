defmodule Robine.Operations.BundledRunnerHealthTest do
  use Robine.DataCase, async: false

  alias Robine.Operations
  alias Robine.Runtime.Dependencies

  test "production health delegates Docker checks to the runner fleet" do
    previous = Application.fetch_env!(:robine, :local_runner_enabled)
    Application.put_env(:robine, :local_runner_enabled, false)
    on_exit(fn -> Application.put_env(:robine, :local_runner_enabled, previous) end)

    context = Dependencies.context(%{id: "admin", role: :administrator}, "bundled-health")
    assert {:ok, health} = Operations.health(%{}, context)
    assert health.checks.docker.status == :optional
    assert health.checks.docker.detail =~ "authenticated runner fleet"
  end
end
