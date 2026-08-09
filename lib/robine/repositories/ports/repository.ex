defmodule Robine.Repositories.Ports.Repository do
  @moduledoc "Repository and webhook-delivery persistence capability."
  alias Robine.Repositories.Domain.{Delivery, Repository}
  @callback upsert_repository(Repository.t()) :: :ok | {:error, term()}
  @callback get_by_provider_id(integer()) :: {:ok, Repository.t()} | {:error, :not_found | term()}
  @callback get_by_id(String.t()) :: {:ok, Repository.t()} | {:error, :not_found | term()}
  @callback list() :: {:ok, [Repository.t()]} | {:error, term()}
  @callback accept_delivery(Delivery.t()) :: {:ok, :accepted | :duplicate} | {:error, term()}
  @callback get_delivery(String.t()) :: {:ok, Delivery.t()} | {:error, :not_found | term()}
  @callback finish_delivery(
              String.t(),
              :processed | :ignored | :failed,
              DateTime.t(),
              String.t() | nil
            ) :: :ok | {:error, term()}
  @callback get_check(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  @callback upsert_check(map()) :: :ok | {:error, term()}
end
