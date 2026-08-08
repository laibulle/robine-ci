defmodule Robine.Storage.Contracts.CacheMetadata do
  @moduledoc "Public cache metadata without a filesystem path."
  @enforce_keys [:key, :digest, :size, :created_at, :expires_at]
  defstruct [:key, :digest, :size, :created_at, :expires_at]

  @type t :: %__MODULE__{
          key: String.t(),
          digest: String.t(),
          size: non_neg_integer(),
          created_at: DateTime.t(),
          expires_at: DateTime.t()
        }
end
