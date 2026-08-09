defmodule Robine.Autoscaling.Ports.Repository do
  @moduledoc "Durable policy, demand, cooldown, and effect-intent boundary."
  alias Robine.Autoscaling.Domain.Policy

  @callback insert_policy(Policy.t(), map()) :: :ok | {:error, term()}
  @callback list_policies() :: {:ok, [Policy.t()]} | {:error, term()}
  @callback queued_demand([String.t()]) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback last_completed_effect(String.t(), :provision | :terminate) ::
              {:ok, DateTime.t() | nil} | {:error, term()}
  @callback reserve_intent(map()) :: {:ok, map()} | {:error, term()}
  @callback complete_intent(String.t(), DateTime.t()) :: :ok | {:error, term()}
  @callback fail_intent(String.t(), String.t(), DateTime.t()) :: :ok | {:error, term()}
end
