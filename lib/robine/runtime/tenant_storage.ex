defmodule Robine.Runtime.TenantStorage do
  @moduledoc false

  alias Robine.Runtime.TenantScope

  @spec namespace() :: String.t() | nil
  def namespace do
    case TenantScope.tenant_id() do
      tenant_id when tenant_id == "standalone" -> nil
      tenant_id -> :crypto.hash(:sha256, tenant_id) |> Base.encode16(case: :lower)
    end
  end

  @spec local_root(String.t()) :: String.t()
  def local_root(base_root) do
    case namespace() do
      nil -> base_root
      namespace -> Path.join([base_root, "tenants", namespace])
    end
  end

  @spec object_prefix(String.t()) :: String.t()
  def object_prefix(configured_prefix) do
    parts =
      [String.trim(configured_prefix, "/"), tenant_part(), "objects"]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(parts, "/") <> "/"
  end

  defp tenant_part do
    case namespace() do
      nil -> nil
      namespace -> "tenants/" <> namespace
    end
  end
end
