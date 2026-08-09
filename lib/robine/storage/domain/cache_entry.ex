defmodule Robine.Storage.Domain.CacheEntry do
  @moduledoc "Repository-scoped exact-key dependency cache metadata."
  @enforce_keys [:id, :repository_id, :key, :blob_id, :digest, :size, :created_at, :expires_at]
  defstruct [
    :id,
    :repository_id,
    :key,
    :blob_id,
    :digest,
    :size,
    :created_at,
    :expires_at,
    :last_restored_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          repository_id: String.t(),
          key: String.t(),
          blob_id: String.t(),
          digest: String.t(),
          size: non_neg_integer(),
          created_at: DateTime.t(),
          expires_at: DateTime.t(),
          last_restored_at: DateTime.t() | nil
        }
end
