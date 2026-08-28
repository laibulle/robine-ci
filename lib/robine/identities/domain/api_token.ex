defmodule Robine.Identities.Domain.ApiToken do
  @moduledoc "A revocable opaque credential global to the instance and scoped by permission."

  @permission "artifacts:write"

  @enforce_keys [
    :id,
    :user_id,
    :name,
    :token_prefix,
    :permissions,
    :expires_at,
    :inserted_at
  ]
  defstruct [
    :id,
    :user_id,
    :name,
    :token_prefix,
    :permissions,
    :expires_at,
    :last_used_at,
    :revoked_at,
    :inserted_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          user_id: String.t(),
          name: String.t(),
          token_prefix: String.t(),
          permissions: [String.t()],
          expires_at: DateTime.t(),
          last_used_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
        }

  @spec artifact_write_permission() :: String.t()
  def artifact_write_permission, do: @permission

  @spec permissions_valid?(term()) :: boolean()
  def permissions_valid?([@permission]), do: true
  def permissions_valid?(_permissions), do: false
end
