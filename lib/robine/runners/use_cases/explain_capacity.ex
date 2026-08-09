defmodule Robine.Runners.UseCases.ExplainCapacity do
  @moduledoc "Explains why a normalized runner requirement can or cannot be placed."

  alias Robine.ExecutionContext
  alias Robine.Runners.Dependencies

  def call(%{labels: labels}, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{runners: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer, :viewer] and is_list(labels) do
    with true <- labels != [] and Enum.all?(labels, &is_binary/1),
         {:ok, fleet} <- deps.registry.list_fleet(deps.clock.now()) do
      matching = Enum.filter(fleet, &matches?(&1, labels))
      local_capacity = Enum.all?(labels, &(&1 == "docker"))

      {:ok,
       %{
         status: if(local_capacity, do: :available, else: placement_status(matching)),
         requested_labels: labels,
         matching_runners: length(matching),
         local_capacity: local_capacity
       }}
    else
      false -> {:error, :invalid_runner_requirements}
      {:error, _reason} = error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp matches?(runner, labels) do
    system =
      [
        if(runner.capabilities["docker"] == true, do: "docker"),
        runner.capabilities["os"],
        runner.capabilities["architecture"]
      ]
      |> Enum.filter(&is_binary/1)

    available = Enum.uniq(runner.labels ++ system)
    Enum.all?(labels, &(&1 in available))
  end

  defp placement_status([]), do: :absent

  defp placement_status(runners) do
    cond do
      Enum.any?(runners, &available?/1) -> :available
      Enum.any?(runners, &busy?/1) -> :busy
      Enum.all?(runners, &(&1.admin_state == :draining)) -> :draining
      true -> :offline
    end
  end

  defp available?(runner),
    do:
      runner.admin_state == :enabled and runner.connectivity == :online and
        runner.available_slots > 0

  defp busy?(runner),
    do:
      runner.admin_state == :enabled and
        (runner.connectivity == :busy or runner.available_slots == 0)
end
