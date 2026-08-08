defmodule Robine.Secrets.Contracts.SecretMetadata do
  @moduledoc "Write-only public representation of a stored secret."
  @enforce_keys [:id, :name, :scope, :inserted_at]
  defstruct [:id, :name, :scope, :repository_id, :allowed_repository_ids, :inserted_at]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          scope: :repository | :instance,
          repository_id: String.t() | nil,
          allowed_repository_ids: [String.t()],
          inserted_at: DateTime.t()
        }
end
