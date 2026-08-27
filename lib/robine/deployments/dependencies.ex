defmodule Robine.Deployments.Dependencies do
  @moduledoc false

  alias Robine.Deployments.Ports

  @enforce_keys [
    :repository,
    :artifact_resolver,
    :container_runtime,
    :verifier,
    :dispatcher,
    :clock,
    :id_generator
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          repository: module(),
          artifact_resolver: module(),
          container_runtime: module(),
          verifier: module(),
          dispatcher: module(),
          clock: module(),
          id_generator: module()
        }

  @spec validate!(t()) :: :ok
  def validate!(%__MODULE__{} = dependencies) do
    for {implementation, behaviour} <- [
          {dependencies.repository, Ports.Repository},
          {dependencies.artifact_resolver, Ports.ArtifactResolver},
          {dependencies.container_runtime, Ports.ContainerRuntime},
          {dependencies.verifier, Ports.Verifier},
          {dependencies.dispatcher, Ports.Dispatcher}
        ] do
      Code.ensure_loaded!(implementation)

      unless behaviour in (implementation.module_info(:attributes)[:behaviour] || []) do
        raise ArgumentError, "#{inspect(implementation)} must implement #{inspect(behaviour)}"
      end
    end

    :ok
  end
end
