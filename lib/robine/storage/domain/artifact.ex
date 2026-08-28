defmodule Robine.Storage.Domain.Artifact do
  @moduledoc "Immutable artifact metadata."
  @enforce_keys [
    :id,
    :repository_id,
    :source,
    :name,
    :content_type,
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
    :source,
    :uploaded_by_id,
    :name,
    :content_type,
    :blob_id,
    :digest,
    :size,
    :created_at,
    :expires_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          repository_id: String.t(),
          attempt_id: String.t() | nil,
          source: :ci | :manual,
          uploaded_by_id: String.t() | nil,
          name: String.t(),
          content_type: String.t(),
          blob_id: String.t(),
          digest: String.t(),
          size: non_neg_integer(),
          created_at: DateTime.t(),
          expires_at: DateTime.t()
        }
end
