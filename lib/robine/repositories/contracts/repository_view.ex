defmodule Robine.Repositories.Contracts.RepositoryView do
  @moduledoc "Public repository metadata and integration health."
  @enforce_keys [:id, :provider, :provider_instance, :full_name, :trusted]
  defstruct [:id, :provider, :provider_instance, :full_name, :trusted]

  @type t :: %__MODULE__{
          id: String.t(),
          provider: :github | :gitlab | :forgejo,
          provider_instance: String.t(),
          full_name: String.t(),
          trusted: boolean()
        }
end
