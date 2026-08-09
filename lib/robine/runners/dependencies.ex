defmodule Robine.Runners.Dependencies do
  @moduledoc false
  alias Robine.Runners.Ports

  @enforce_keys [:registry, :digester, :token_generator, :session_notifier, :clock, :id_generator]
  defstruct [:registry, :digester, :token_generator, :session_notifier, :clock, :id_generator]

  @type t :: %__MODULE__{
          registry: module(),
          digester: module(),
          token_generator: module(),
          session_notifier: module(),
          clock: module(),
          id_generator: module()
        }

  def validate!(%__MODULE__{} = dependencies) do
    for {implementation, behaviour} <- [
          {dependencies.registry, Ports.Registry},
          {dependencies.digester, Ports.CredentialDigester},
          {dependencies.token_generator, Ports.TokenGenerator},
          {dependencies.session_notifier, Ports.SessionNotifier}
        ] do
      Code.ensure_loaded!(implementation)

      unless behaviour in (implementation.module_info(:attributes)[:behaviour] || []),
        do:
          raise(ArgumentError, "#{inspect(implementation)} must implement #{inspect(behaviour)}")
    end

    :ok
  end
end
