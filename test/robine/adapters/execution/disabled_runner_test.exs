defmodule Robine.Adapters.Execution.DisabledRunnerTest do
  use ExUnit.Case, async: true

  alias Robine.Adapters.Execution.DisabledRunner

  test "rejects execution and treats runner-owned resources as external" do
    assert {:error, :local_runner_disabled} =
             DisabledRunner.run(%{}, fn _event -> :ok end, fn -> false end)

    assert {:ok, %{containers_removed: 0, volumes_removed: 0}} =
             DisabledRunner.reconcile_resources(["attempt-id"])
  end
end
