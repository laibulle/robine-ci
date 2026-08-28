defmodule Robine.Identities.Dependencies do
  @moduledoc false
  alias Robine.Identities.Ports

  @enforce_keys [
    :repository,
    :passwords,
    :oidc,
    :token_generator,
    :clock,
    :id_generator,
    :bootstrap_token_hash,
    :bootstrap_expires_at
  ]
  defstruct [
    :repository,
    :passwords,
    :oidc,
    :oidc_config,
    :token_generator,
    :clock,
    :id_generator,
    :bootstrap_token_hash,
    :bootstrap_expires_at
  ]

  @type t :: %__MODULE__{
          repository: module(),
          passwords: module(),
          oidc: module(),
          oidc_config: keyword() | nil,
          token_generator: module(),
          clock: module(),
          id_generator: module(),
          bootstrap_token_hash: binary(),
          bootstrap_expires_at: DateTime.t()
        }

  def validate!(%__MODULE__{} = dependencies) do
    for {implementation, behaviour} <- [
          {dependencies.repository, Ports.Repository},
          {dependencies.passwords, Ports.Passwords},
          {dependencies.oidc, Ports.OIDC},
          {dependencies.token_generator, Ports.TokenGenerator}
        ] do
      Code.ensure_loaded!(implementation)

      unless behaviour in (implementation.module_info(:attributes)[:behaviour] || []),
        do:
          raise(ArgumentError, "#{inspect(implementation)} must implement #{inspect(behaviour)}")
    end

    :ok
  end
end
