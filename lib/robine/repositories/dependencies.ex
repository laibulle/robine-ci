defmodule Robine.Repositories.Dependencies do
  @moduledoc false
  alias Robine.Repositories.Ports
  @enforce_keys [:repository, :signature_verifier, :github, :clock, :id_generator, :public_url]
  defstruct [:repository, :signature_verifier, :github, :clock, :id_generator, :public_url]

  @type t :: %__MODULE__{
          repository: module(),
          signature_verifier: module(),
          github: module(),
          clock: module(),
          id_generator: module(),
          public_url: String.t()
        }

  @spec validate!(t()) :: :ok
  def validate!(%__MODULE__{} = dependencies) do
    for {implementation, behaviour} <- [
          {dependencies.repository, Ports.Repository},
          {dependencies.signature_verifier, Ports.SignatureVerifier},
          {dependencies.github, Ports.GitHub}
        ] do
      Code.ensure_loaded!(implementation)

      unless behaviour in (implementation.module_info(:attributes)[:behaviour] || []),
        do:
          raise(ArgumentError, "#{inspect(implementation)} must implement #{inspect(behaviour)}")
    end

    :ok
  end
end
