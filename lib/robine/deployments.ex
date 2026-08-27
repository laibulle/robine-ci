defmodule Robine.Deployments do
  @moduledoc "Public API for native immutable-artifact deployments."

  alias Robine.Deployments.UseCases
  alias Robine.ExecutionContext

  @spec configure_environment(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate configure_environment(input, context),
    to: UseCases.ConfigureEnvironment,
    as: :call

  @spec get_repository_overview(map(), ExecutionContext.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate get_repository_overview(input, context),
    to: UseCases.GetRepositoryOverview,
    as: :call

  @spec request_deployment(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate request_deployment(input, context),
    to: UseCases.RequestDeployment,
    as: :call

  @spec approve_deployment(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate approve_deployment(input, context),
    to: UseCases.ApproveDeployment,
    as: :call

  @spec record_runner_event(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate record_runner_event(input, context),
    to: UseCases.RecordRunnerEvent,
    as: :call

  @spec cancel_deployment(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate cancel_deployment(input, context),
    to: UseCases.CancelDeployment,
    as: :call
end
