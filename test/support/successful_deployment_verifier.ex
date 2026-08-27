defmodule Robine.TestSupport.SuccessfulDeploymentVerifier do
  @moduledoc false
  @behaviour Robine.Deployments.Ports.Verifier

  @impl true
  def verify(_verification, release, _options),
    do: {:ok, %{status: 200, release: release}}
end
