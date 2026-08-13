defmodule Robine.Backend do
  @moduledoc "Tenant-safe entry point for applications embedding the Robine CI backend."

  alias Robine.ExecutionContext
  alias Robine.Runtime.TenantScope

  @facades [
    Robine.Autoscaling,
    Robine.Execution,
    Robine.Operations,
    Robine.Pipelines,
    Robine.Repositories,
    Robine.Runners,
    Robine.Secrets,
    Robine.Storage,
    Robine.Transfers,
    Robine.Workflows
  ]

  @spec call(ExecutionContext.t(), module(), atom(), [term()]) :: term()
  def call(context, facade, operation, arguments \\ [])

  def call(%ExecutionContext{} = context, facade, operation, arguments)
      when facade in @facades and is_atom(operation) and is_list(arguments) do
    arity = length(arguments) + 1

    if Code.ensure_loaded?(facade) and function_exported?(facade, operation, arity) do
      invoke(context, fn -> apply(facade, operation, arguments ++ [context]) end)
    else
      {:error, :unsupported_backend_operation}
    end
  end

  def call(%ExecutionContext{}, _facade, _operation, _arguments),
    do: {:error, :unsupported_backend_operation}

  def call(_context, _facade, _operation, _arguments), do: {:error, :invalid_execution_context}

  @spec subscribe(ExecutionContext.t(), String.t()) :: :ok | {:error, term()}
  def subscribe(%ExecutionContext{} = context, topic) when is_binary(topic) and topic != "" do
    if ExecutionContext.capable?(context, :ci_read) do
      Phoenix.PubSub.subscribe(Robine.PubSub, tenant_topic(context.tenant_id, topic))
    else
      {:error, :forbidden}
    end
  end

  @spec tenant_topic(String.t(), String.t()) :: String.t()
  def tenant_topic(tenant_id, topic) when is_binary(tenant_id) and is_binary(topic),
    do: "tenant:" <> tenant_id <> ":" <> topic

  defp invoke(%ExecutionContext{tenant_id: tenant_id}, callback)
       when tenant_id == "standalone",
       do: callback.()

  defp invoke(context, callback), do: TenantScope.run(context, callback)
end
