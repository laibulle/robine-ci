defmodule Robine.Storage.Domain.Artifact do
  @moduledoc "Immutable artifact metadata."
  @enforce_keys [
    :id,
    :repository_id,
    :attempt_id,
    :name,
    :blob_id,
    :digest,
    :size,
    :created_at,
    :expires_at
  ]
  defstruct [
    :id,
    :repository_id,
    :attempt_id,
    :name,
    :blob_id,
    :digest,
    :size,
    :created_at,
    :expires_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          repository_id: String.t(),
          attempt_id: String.t(),
          name: String.t(),
          blob_id: String.t(),
          digest: String.t(),
          size: non_neg_integer(),
          created_at: DateTime.t(),
          expires_at: DateTime.t()
        }
end
