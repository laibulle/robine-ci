defmodule Robine.TestSupport.FakeAutoscalingProvider do
  @moduledoc false
  @behaviour Robine.Autoscaling.Ports.Provider

  def child_spec(options) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}}
  end

  def start_link(options) do
    Agent.start_link(
      fn -> %{instances: [], calls: [], failure: Keyword.get(options, :failure)} end,
      name: __MODULE__
    )
  end

  def set_failure(failure), do: Agent.update(__MODULE__, &%{&1 | failure: failure})
  def set_instances(instances), do: Agent.update(__MODULE__, &%{&1 | instances: instances})
  def state, do: Agent.get(__MODULE__, & &1)

  @impl true
  def describe(_template), do: {:ok, Agent.get(__MODULE__, & &1.instances)}

  @impl true
  def provision(_template, key) do
    Agent.get_and_update(__MODULE__, fn state ->
      calls = [{:provision, key} | state.calls]

      case state.failure do
        :before_effect ->
          {{:error, :temporary_provider_failure}, %{state | calls: calls}}

        _healthy ->
          instance = %{
            id: "instance-#{String.slice(key, 0, 12)}",
            state: :ready,
            active_leases: 0,
            last_active_at: DateTime.add(DateTime.utc_now(), -3_600, :second)
          }

          instances = Enum.uniq_by([instance | state.instances], & &1.id)
          {{:ok, instance}, %{state | instances: instances, calls: calls}}
      end
    end)
  end

  @impl true
  def terminate(instance_id, key) do
    Agent.update(__MODULE__, fn state ->
      %{
        state
        | instances: Enum.reject(state.instances, &(&1.id == instance_id)),
          calls: [{:terminate, key, instance_id} | state.calls]
      }
    end)

    :ok
  end
end
