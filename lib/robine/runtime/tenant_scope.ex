defmodule Robine.Runtime.TenantScope do
  @moduledoc false

  alias Robine.ExecutionContext
  alias Robine.Repo
  alias Robine.Runtime.TenantRegistry

  @tenant_key {__MODULE__, :tenant_id}

  @spec run(ExecutionContext.t(), (-> result)) :: result | {:error, term()} when result: term()
  def run(%ExecutionContext{} = context, callback) when is_function(callback, 0) do
    previous_tenant = Process.get(@tenant_key)

    cond do
      previous_tenant == context.tenant_id ->
        callback.()

      not is_nil(previous_tenant) ->
        {:error, :tenant_scope_mismatch}

      true ->
        Process.put(@tenant_key, context.tenant_id)

        try do
          run_database_scope(context.tenant_id, callback)
        after
          Process.delete(@tenant_key)
        end
    end
  end

  @spec tenant_id() :: String.t()
  def tenant_id, do: Process.get(@tenant_key, ExecutionContext.standalone_tenant())

  defp run_database_scope(tenant_id, callback) do
    if Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
      Repo.transaction(fn ->
        :ok = TenantRegistry.register(tenant_id)
        Repo.query!("SELECT set_config('robine.tenant_id', $1, true)", [tenant_id])
        callback.()
      end)
      |> unwrap_transaction()
    else
      Repo.checkout(fn ->
        :ok = TenantRegistry.register(tenant_id)
        Repo.query!("SELECT set_config('robine.tenant_id', $1, false)", [tenant_id])

        try do
          callback.()
        after
          Repo.query!("SELECT set_config('robine.tenant_id', '', false)", [])
        end
      end)
    end
  end

  defp unwrap_transaction({:ok, result}), do: result
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
