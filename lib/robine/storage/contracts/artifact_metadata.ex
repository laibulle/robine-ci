defmodule Robine.Storage.Contracts.ArtifactMetadata do
  @moduledoc "Public artifact metadata without a filesystem path."
  @enforce_keys [
    :id,
    :source,
    :name,
    :content_type,
    :digest,
    :size,
    :created_at,
    :expires_at
  ]
  defstruct [
    :id,
    :source,
    :uploaded_by_id,
    :name,
    :content_type,
    :digest,
    :size,
    :created_at,
    :expires_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          source: :ci | :manual,
          uploaded_by_id: String.t() | nil,
          name: String.t(),
          content_type: String.t(),
          digest: String.t(),
          size: non_neg_integer(),
          created_at: DateTime.t(),
          expires_at: DateTime.t()
        }
end
