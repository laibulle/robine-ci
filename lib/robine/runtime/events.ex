defmodule Robine.Runtime.Events do
  @moduledoc false

  alias Robine.ExecutionContext
  alias Robine.Runtime.TenantScope

  @spec broadcast(String.t(), term()) :: :ok | {:error, term()}
  def broadcast(topic, event) when is_binary(topic) do
    tenant_id = TenantScope.tenant_id()

    with :ok <-
           Phoenix.PubSub.broadcast(
             Robine.PubSub,
             Robine.Backend.tenant_topic(tenant_id, topic),
             event
           ) do
      broadcast_standalone_compatibility(tenant_id, topic, event)
    end
  end

  defp broadcast_standalone_compatibility(tenant_id, topic, event) do
    if tenant_id == ExecutionContext.standalone_tenant() do
      Phoenix.PubSub.broadcast(Robine.PubSub, topic, event)
    else
      :ok
    end
  end
end
