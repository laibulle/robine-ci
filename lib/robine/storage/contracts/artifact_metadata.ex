defmodule Robine.Storage.Contracts.ArtifactMetadata do
  @moduledoc "Public artifact metadata without a filesystem path."
  @enforce_keys [:id, :name, :digest, :size, :created_at, :expires_at]
  defstruct [:id, :name, :digest, :size, :created_at, :expires_at]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          digest: String.t(),
          size: non_neg_integer(),
          created_at: DateTime.t(),
          expires_at: DateTime.t()
        }
end
