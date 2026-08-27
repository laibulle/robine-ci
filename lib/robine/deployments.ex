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

  @spec verify_deployment(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate verify_deployment(input, context),
    to: UseCases.VerifyDeployment,
    as: :call

  @spec retry_verification(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate retry_verification(input, context),
    to: UseCases.RetryVerification,
    as: :call

  @spec next_queued_deployment(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate next_queued_deployment(input, context),
    to: UseCases.NextQueuedDeployment,
    as: :call

  @spec assign_deployment(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate assign_deployment(input, context),
    to: UseCases.AssignDeployment,
    as: :call

  @spec remote_execution(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate remote_execution(input, context),
    to: UseCases.RemoteExecution,
    as: :call
end
