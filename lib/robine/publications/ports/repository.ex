defmodule Robine.Publications.Ports.Repository do
  @moduledoc "Durable public-release policy and projection boundary."
  alias Robine.Publications.Domain.RepositoryPolicy

  @callback get_policy(String.t()) :: {:ok, RepositoryPolicy.t() | nil} | {:error, term()}
  @callback upsert_policy(RepositoryPolicy.t(), map()) :: :ok | {:error, term()}
  @callback list_publications(String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback find_latest_published(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
end
