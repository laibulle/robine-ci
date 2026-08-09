defmodule Robine.Adapters.Persistence.Postgres.UnitOfWork do
  @moduledoc false
  @behaviour Robine.Pipelines.Ports.UnitOfWork

  alias Robine.Repo

  @impl true
  def transaction(operation) when is_function(operation, 0) do
    Repo.transaction(fn ->
      case operation.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @impl true
  def lock(identity) when is_binary(identity) do
    <<key::signed-64, _rest::binary>> = :crypto.hash(:sha256, identity)

    case Ecto.Adapters.SQL.query(Repo, "SELECT pg_advisory_xact_lock($1)", [key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:advisory_lock, reason}}
    end
  end
end
