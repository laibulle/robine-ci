defmodule Robine.Pipelines do
  @moduledoc "Public application API for pipeline operations."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Contracts.PipelineView
  alias Robine.Pipelines.UseCases

  @spec create_pipeline(map(), ExecutionContext.t()) ::
          {:ok, PipelineView.t()} | {:error, term()}
  defdelegate create_pipeline(input, context), to: UseCases.CreatePipeline, as: :call

  @spec queue_pipeline(map(), ExecutionContext.t()) ::
          {:ok, PipelineView.t()} | {:error, term()}
  defdelegate queue_pipeline(input, context), to: UseCases.QueuePipeline, as: :call

  @spec cancel_pipeline(map(), ExecutionContext.t()) ::
          {:ok, PipelineView.t()} | {:error, term()}
  defdelegate cancel_pipeline(input, context), to: UseCases.CancelPipeline, as: :call

  @spec deliver_event(map(), ExecutionContext.t()) :: {:ok, :delivered} | {:error, term()}
  defdelegate deliver_event(input, context), to: UseCases.DeliverEvent, as: :call

  @spec claim_next_job(map(), ExecutionContext.t()) ::
          {:ok, Robine.Pipelines.Domain.Attempt.t()} | {:error, term()}
  defdelegate claim_next_job(input, context), to: UseCases.ClaimNextJob, as: :call

  @spec record_runner_event(map(), ExecutionContext.t()) ::
          {:ok, Robine.Pipelines.Domain.Attempt.t()} | {:error, term()}
  defdelegate record_runner_event(input, context), to: UseCases.RecordRunnerEvent, as: :call

  @spec reconcile_expired_leases(map(), ExecutionContext.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate reconcile_expired_leases(input, context),
    to: UseCases.ReconcileExpiredLeases,
    as: :call

  @spec job_execution(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate job_execution(input, context), to: UseCases.GetJobExecution, as: :call
end
