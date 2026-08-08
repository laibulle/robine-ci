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
end
