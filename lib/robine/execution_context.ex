defmodule Robine.ExecutionContext do
  @moduledoc """
  Request-scoped actor, correlation metadata, and explicitly assembled dependencies.

  Delivery adapters obtain contexts from `Robine.Runtime.Dependencies`. Unit tests
  may construct contexts with deterministic fake dependencies.
  """

  @standalone_tenant "standalone"
  @supported_capabilities MapSet.new([:ci_read, :ci_run, :ci_manage, :ci_runner])
  @enforce_keys [:actor, :tenant_id, :capabilities, :correlation_id, :dependencies]
  defstruct [:actor, :tenant_id, :capabilities, :correlation_id, :dependencies]

  @type actor :: %{required(:id) => String.t(), required(:role) => atom()}
  @type capability :: atom()
  @type t :: %__MODULE__{
          actor: actor(),
          tenant_id: String.t(),
          capabilities: MapSet.t(capability()),
          correlation_id: String.t(),
          dependencies: map()
        }

  @spec new(actor(), String.t(), map()) :: t()
  def new(actor, correlation_id, dependencies)
      when is_map(actor) and is_binary(correlation_id) and is_map(dependencies) do
    %__MODULE__{
      actor: actor,
      tenant_id: @standalone_tenant,
      capabilities: capabilities_for_role(Map.get(actor, :role)),
      correlation_id: correlation_id,
      dependencies: dependencies
    }
  end

  @doc "Builds a tenant-scoped context supplied by an embedding host."
  @spec embedded(actor(), String.t(), [capability()], String.t(), map()) ::
          {:ok, t()} | {:error, :invalid_execution_context}
  def embedded(actor, tenant_id, capabilities, correlation_id, dependencies \\ %{})

  def embedded(actor, tenant_id, capabilities, correlation_id, dependencies)
      when is_map(actor) and is_binary(tenant_id) and is_list(capabilities) and
             is_binary(correlation_id) and is_map(dependencies) do
    capability_set = MapSet.new(capabilities)

    if valid_identifier?(Map.get(actor, :id)) and valid_identifier?(tenant_id) and
         valid_identifier?(correlation_id) and MapSet.size(capability_set) > 0 and
         MapSet.subset?(capability_set, @supported_capabilities) and
         valid_capability_combination?(capability_set) do
      {:ok,
       %__MODULE__{
         actor: Map.put(actor, :role, role_for_capabilities(capability_set)),
         tenant_id: tenant_id,
         capabilities: capability_set,
         correlation_id: correlation_id,
         dependencies: dependencies
       }}
    else
      {:error, :invalid_execution_context}
    end
  end

  def embedded(_actor, _tenant_id, _capabilities, _correlation_id, _dependencies),
    do: {:error, :invalid_execution_context}

  @spec capable?(t(), capability()) :: boolean()
  def capable?(%__MODULE__{capabilities: capabilities}, capability) when is_atom(capability) do
    MapSet.member?(capabilities, capability) or implied_capability?(capabilities, capability)
  end

  @spec standalone_tenant() :: String.t()
  def standalone_tenant, do: @standalone_tenant

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp implied_capability?(capabilities, :ci_read),
    do: MapSet.member?(capabilities, :ci_run) or MapSet.member?(capabilities, :ci_manage)

  defp implied_capability?(capabilities, :ci_run), do: MapSet.member?(capabilities, :ci_manage)
  defp implied_capability?(_capabilities, _capability), do: false

  defp valid_capability_combination?(capabilities) do
    not (MapSet.member?(capabilities, :ci_runner) and MapSet.size(capabilities) > 1)
  end

  defp role_for_capabilities(capabilities) do
    cond do
      MapSet.member?(capabilities, :ci_runner) -> :runner
      MapSet.member?(capabilities, :ci_manage) -> :administrator
      MapSet.member?(capabilities, :ci_run) -> :maintainer
      true -> :viewer
    end
  end

  defp capabilities_for_role(:administrator), do: MapSet.new([:ci_read, :ci_run, :ci_manage])
  defp capabilities_for_role(:maintainer), do: MapSet.new([:ci_read, :ci_run])
  defp capabilities_for_role(:viewer), do: MapSet.new([:ci_read])
  defp capabilities_for_role(:runner), do: MapSet.new([:ci_runner])
  defp capabilities_for_role(_role), do: MapSet.new()
end
