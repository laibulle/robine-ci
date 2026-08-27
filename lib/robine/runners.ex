defmodule Robine.Runners do
  @moduledoc "Public application API for remote runner identity and lifecycle."

  alias Robine.ExecutionContext
  alias Robine.Runners.UseCases

  @spec create_enrollment_token(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate create_enrollment_token(input, context),
    to: UseCases.CreateEnrollmentToken,
    as: :call

  @spec enroll(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate enroll(input, context), to: UseCases.Enroll, as: :call

  @spec authenticate(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate authenticate(input, context), to: UseCases.Authenticate, as: :call

  @spec negotiate_protocol(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate negotiate_protocol(input, context), to: UseCases.NegotiateProtocol, as: :call

  @spec heartbeat(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate heartbeat(input, context), to: UseCases.Heartbeat, as: :call

  @spec select_available(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate select_available(input, context), to: UseCases.SelectAvailableRunner, as: :call

  @spec select_deployment_runner(map(), ExecutionContext.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate select_deployment_runner(input, context),
    to: UseCases.SelectDeploymentRunner,
    as: :call

  @spec list_fleet(map(), ExecutionContext.t()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_fleet(input, context), to: UseCases.ListFleet, as: :call

  @spec update_runner(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate update_runner(input, context), to: UseCases.UpdateRunner, as: :call

  @spec explain_capacity(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate explain_capacity(input, context), to: UseCases.ExplainCapacity, as: :call

  @spec rotate_credential(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate rotate_credential(input, context), to: UseCases.RotateCredential, as: :call

  @spec revoke(map(), ExecutionContext.t()) :: :ok | {:error, term()}
  defdelegate revoke(input, context), to: UseCases.Revoke, as: :call
end
