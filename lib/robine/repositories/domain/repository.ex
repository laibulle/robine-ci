defmodule Robine.Repositories.Domain.Repository do
  @moduledoc "A trusted source-control repository installed on this Robine instance."
  @enforce_keys [
    :id,
    :provider,
    :provider_instance,
    :provider_id,
    :installation_id,
    :owner,
    :name,
    :full_name,
    :trusted,
    :inserted_at
  ]
  defstruct [
    :id,
    :provider,
    :provider_instance,
    :provider_id,
    :installation_id,
    :owner,
    :name,
    :full_name,
    :trusted,
    :inserted_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          provider: :github | :gitlab | :forgejo,
          provider_instance: String.t(),
          provider_id: integer(),
          installation_id: integer(),
          owner: String.t(),
          name: String.t(),
          full_name: String.t(),
          trusted: boolean(),
          inserted_at: DateTime.t()
        }
end
