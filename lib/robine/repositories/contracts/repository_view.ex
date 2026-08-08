defmodule Robine.Repositories.Contracts.RepositoryView do
  @moduledoc "Public repository metadata and integration health."
  @enforce_keys [:id, :full_name, :trusted]
  defstruct [:id, :full_name, :trusted]
  @type t :: %__MODULE__{id: String.t(), full_name: String.t(), trusted: boolean()}
end
