defmodule Robine.Adapters.Background.TenantJob do
  @moduledoc false

  alias Robine.ExecutionContext
  alias Robine.Runtime
  alias Robine.Runtime.Dependencies
  alias Robine.Runtime.TenantRegistry
  alias Robine.Runtime.TenantScope

  @spec put_tenant(map()) :: map()
  def put_tenant(arguments) when is_map(arguments) do
    Map.put(arguments, :tenant_id, TenantScope.tenant_id())
  end

  @spec tenant_id(map()) :: String.t()
  def tenant_id(arguments) when is_map(arguments) do
    Map.get(arguments, "tenant_id", ExecutionContext.standalone_tenant())
  end

  @spec run(Oban.Job.t(), module(), String.t(), (ExecutionContext.t() -> term())) :: term()
  def run(%Oban.Job{args: arguments}, worker, correlation_id, callback)
      when is_atom(worker) and is_binary(correlation_id) and is_function(callback, 1) do
    arguments = arguments || %{}

    if Runtime.configured_profile() == :embedded and not Map.has_key?(arguments, "tenant_id") do
      dispatch_for_all_tenants(worker)
    else
      context =
        Dependencies.system_context(tenant_id(arguments), system_actor(worker), correlation_id)

      if context.tenant_id == ExecutionContext.standalone_tenant() do
        callback.(context)
      else
        TenantScope.run(context, fn -> callback.(context) end)
      end
    end
  end

  defp dispatch_for_all_tenants(worker) do
    TenantRegistry.list()
    |> Enum.reduce_while(:ok, fn tenant_id, :ok ->
      case %{tenant_id: tenant_id} |> worker.new() |> Oban.insert() do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp system_actor(Robine.Adapters.Background.ReconcileLeasesWorker),
    do: "system:lease-reconciler"

  defp system_actor(Robine.Adapters.Background.ReconcileOutboxWorker),
    do: "system:outbox-reconciler"

  defp system_actor(Robine.Adapters.Background.ReconcileAutoscalingWorker),
    do: "system:autoscaler"

  defp system_actor(Robine.Adapters.Background.ReconcileScheduledWorkflowsWorker),
    do: "system:scheduler"

  defp system_actor(Robine.Adapters.Background.ReconcileGitHubChecksWorker),
    do: "system:github-check-reconciler"

  defp system_actor(Robine.Adapters.Background.ReconcileRunnerResourcesWorker),
    do: "system:runner-reconciler"

  defp system_actor(Robine.Adapters.Background.PruneRetentionWorker), do: "system:retention"
  defp system_actor(Robine.Adapters.Background.OutboxDeliveryWorker), do: "system:outbox"
  defp system_actor(Robine.Adapters.Background.RunNextJobWorker), do: "system:local-runner"
  defp system_actor(_worker), do: "system:backend"
end
