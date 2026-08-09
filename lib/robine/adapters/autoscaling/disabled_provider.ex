defmodule Robine.Adapters.Autoscaling.DisabledProvider do
  @moduledoc "Default adapter that keeps autoscaling effects explicitly disabled."
  @behaviour Robine.Autoscaling.Ports.Provider
  @impl true
  def describe(_template), do: {:error, :autoscaling_provider_disabled}
  @impl true
  def provision(_template, _idempotency_key), do: {:error, :autoscaling_provider_disabled}
  @impl true
  def terminate(_instance_id, _idempotency_key), do: {:error, :autoscaling_provider_disabled}
end
