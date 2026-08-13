defmodule Robine.Runtime.TenantRegistry do
  @moduledoc false

  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.Tenant
  alias Robine.ExecutionContext
  alias Robine.Repo

  @spec register(String.t()) :: :ok | {:error, term()}
  def register(tenant_id) when is_binary(tenant_id) and tenant_id != "" do
    now = DateTime.utc_now()

    case Repo.insert_all(
           Tenant,
           [%{id: tenant_id, inserted_at: now}],
           on_conflict: :nothing,
           conflict_target: [:id]
         ) do
      {_count, nil} -> :ok
      {_count, _rows} -> :ok
    end
  end

  @spec list() :: [String.t()]
  def list do
    case Repo.all(from tenant in Tenant, order_by: [asc: tenant.inserted_at], select: tenant.id) do
      [] -> [ExecutionContext.standalone_tenant()]
      tenants -> tenants
    end
  end
end
