defmodule Robine.Adapters.Background.ReconcileRunnerResourcesWorkerTest do
  use ExUnit.Case, async: false

  alias Robine.Adapters.Background.ReconcileRunnerResourcesWorker

  test "does not touch Docker resources when local execution is disabled" do
    previous = Application.fetch_env!(:robine, :local_runner_enabled)
    Application.put_env(:robine, :local_runner_enabled, false)
    on_exit(fn -> Application.put_env(:robine, :local_runner_enabled, previous) end)

    assert :ok = ReconcileRunnerResourcesWorker.perform(%Oban.Job{id: 42})
  end
end
