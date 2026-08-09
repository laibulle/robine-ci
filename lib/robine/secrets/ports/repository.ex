defmodule Robine.Secrets.Ports.Repository do
  @moduledoc "Secret persistence and atomic audit capability."
  alias Robine.Secrets.Domain.Secret
  @callback upsert(Secret.t(), map()) :: :ok | {:error, term()}
  @callback find_authorized(String.t(), [String.t()]) :: {:ok, [Secret.t()]} | {:error, term()}
  @callback find_instance([String.t()]) :: {:ok, [Secret.t()]} | {:error, term()}
  @callback list_metadata(String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback list_for_rotation(pos_integer(), String.t() | nil, pos_integer()) ::
              {:ok, [Secret.t()]} | {:error, term()}
  @callback rotate(Secret.t(), pos_integer(), map()) :: :ok | {:error, term()}
end
