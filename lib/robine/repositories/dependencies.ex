defmodule Robine.Repositories.Dependencies do
  @moduledoc false
  alias Robine.Repositories.Ports

  @enforce_keys [
    :repository,
    :webhook_verifier,
    :source_control,
    :clock,
    :id_generator,
    :public_url
  ]
  defstruct [
    :repository,
    :webhook_verifier,
    :source_control,
    :clock,
    :id_generator,
    :public_url
  ]

  @type t :: %__MODULE__{
          repository: module(),
          webhook_verifier: module(),
          source_control: module(),
          clock: module(),
          id_generator: module(),
          public_url: String.t()
        }

  @spec validate!(t()) :: :ok
  def validate!(%__MODULE__{} = dependencies) do
    for {implementation, behaviour} <- [
          {dependencies.repository, Ports.Repository},
          {dependencies.webhook_verifier, Ports.WebhookVerifier},
          {dependencies.source_control, Ports.SourceControl}
        ] do
      Code.ensure_loaded!(implementation)

      unless behaviour in (implementation.module_info(:attributes)[:behaviour] || []),
        do:
          raise(ArgumentError, "#{inspect(implementation)} must implement #{inspect(behaviour)}")
    end

    :ok
  end
end
