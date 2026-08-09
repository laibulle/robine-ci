defmodule Robine.Autoscaling.Ports.Provider do
  @moduledoc "Infrastructure effects for one provider-neutral runner template."
  @callback describe(map()) :: {:ok, [map()]} | {:error, term()}
  @callback provision(map(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback terminate(String.t(), String.t()) :: :ok | {:error, term()}
end
