defmodule Robine.Adapters.Persistence.Postgres.TenantGuard do
  @moduledoc false

  alias Robine.Repo

  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]},
      restart: :transient
    }
  end

  def start_link(options) do
    case Keyword.fetch!(options, :profile) do
      :standalone -> :ignore
      :embedded -> verify_embedded_database_role()
    end
  end

  defp verify_embedded_database_role do
    case Repo.query(
           "SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user",
           []
         ) do
      {:ok, %{rows: [[false, false]]}} ->
        :ignore

      {:ok, %{rows: [[_superuser, _bypass_rls]]}} ->
        {:error,
         "embedded Robine requires a PostgreSQL role without SUPERUSER and BYPASSRLS privileges"}

      {:error, reason} ->
        {:error, {:tenant_database_role_check_failed, reason}}
    end
  end
end
