defmodule Robine.Storage.Ports.BlobStore do
  @moduledoc "Opaque content-addressed blob storage capability."
  @callback put(binary()) ::
              {:ok, %{blob_id: String.t(), digest: String.t(), size: non_neg_integer()}}
              | {:error, term()}
  @callback get(String.t(), String.t()) ::
              {:ok, binary()} | {:error, :not_found | :digest_mismatch | term()}
  @callback delete(String.t()) :: :ok | {:error, term()}
end
