defmodule Robine.Identities.Domain.User do
  @moduledoc "Framework-free user identity."
  @roles [:administrator, :maintainer, :viewer]
  @enforce_keys [:id, :email, :role, :disabled]
  defstruct [:id, :email, :role, :disabled, :inserted_at]

  @type t :: %__MODULE__{
          id: binary(),
          email: String.t(),
          role: atom(),
          disabled: boolean(),
          inserted_at: DateTime.t() | nil
        }
  def roles, do: @roles
end
