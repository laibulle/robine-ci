defmodule Robine.Deployments.Ports.Repository do
  @moduledoc "Durable environment, deployment, event, and audit boundary."

  alias Robine.Deployments.Domain.{Deployment, Environment}

  @callback get_environment(String.t()) :: {:ok, Environment.t()} | {:error, term()}
  @callback get_environment_by_name(String.t(), String.t()) ::
              {:ok, Environment.t()} | {:error, term()}
  @callback list_environments(String.t()) :: {:ok, [Environment.t()]} | {:error, term()}
  @callback upsert_environment(Environment.t(), map()) :: :ok | {:error, term()}
  @callback insert_deployment(Deployment.t(), map()) :: :ok | {:error, term()}
  @callback get_deployment(String.t()) :: {:ok, Deployment.t()} | {:error, term()}
  @callback find_equivalent_deployment(String.t(), String.t(), atom()) ::
              {:ok, Deployment.t()} | {:error, term()}
  @callback update_deployment(Deployment.t(), atom(), map()) :: :ok | {:error, term()}
  @callback record_event(Deployment.t(), atom(), String.t() | nil, DateTime.t(), map()) ::
              :ok | {:error, term()}
  @callback find_event(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  @callback list_deployments(String.t()) :: {:ok, [Deployment.t()]} | {:error, term()}
  @callback next_queued() :: {:ok, Deployment.t()} | {:error, :none}
  @callback get_runner_deployment(String.t(), String.t()) ::
              {:ok, Deployment.t()} | {:error, term()}
end
