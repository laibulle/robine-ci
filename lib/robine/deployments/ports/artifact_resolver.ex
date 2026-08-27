defmodule Robine.Deployments.Ports.ArtifactResolver do
  @moduledoc "Resolves a deployable artifact from a successful exact tag pipeline."

  @callback resolve(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
end
