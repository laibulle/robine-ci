defmodule Robine.Adapters.Execution.DisabledRunner do
  @moduledoc "Rejects direct execution when jobs must be handled by remote runners."

  @behaviour Robine.Execution.Ports.Runner

  @impl true
  def run(_specification, _on_output, _cancel_requested),
    do: {:error, :local_runner_disabled}

  @impl true
  def reconcile_resources(_active_attempt_ids),
    do: {:ok, %{containers_removed: 0, volumes_removed: 0}}
end
