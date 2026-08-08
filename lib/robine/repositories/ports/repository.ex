defmodule Robine.Repositories.Ports.Repository do
  @moduledoc "Repository and webhook-delivery persistence capability."
  alias Robine.Repositories.Domain.{Delivery, Repository}
  @callback upsert_repository(Repository.t()) :: :ok | {:error, term()}
  @callback get_by_provider_id(integer()) :: {:ok, Repository.t()} | {:error, :not_found | term()}
  @callback accept_delivery(Delivery.t()) :: {:ok, :accepted | :duplicate} | {:error, term()}
  @callback get_delivery(String.t()) :: {:ok, Delivery.t()} | {:error, :not_found | term()}
  @callback finish_delivery(
              String.t(),
              :processed | :ignored | :failed,
              DateTime.t(),
              String.t() | nil
            ) :: :ok | {:error, term()}
end
