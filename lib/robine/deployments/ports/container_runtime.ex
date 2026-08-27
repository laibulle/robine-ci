defmodule Robine.Deployments.Ports.ContainerRuntime do
  @moduledoc "Converges one bounded environment without exposing arbitrary Docker operations."

  alias Robine.Deployments.Domain.Environment

  @callback converge(Environment.t(), :application | :platform, map(), keyword()) ::
              {:ok, map()} | {:error, term()}
end
