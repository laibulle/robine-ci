defmodule Robine.Adapters.Storage.S3Client do
  @moduledoc false

  @callback put_file(String.t(), String.t(), String.t(), non_neg_integer(), keyword()) ::
              :ok | {:error, term()}
  @callback get(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  @callback delete(String.t(), keyword()) :: :ok | {:error, term()}
  @callback inventory(String.t(), keyword()) ::
              {:ok, [%{key: String.t(), size: non_neg_integer()}]} | {:error, term()}
  @callback health(keyword()) :: :ok | {:error, term()}
end
