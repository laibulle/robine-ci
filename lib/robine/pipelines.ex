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

  @spec deliver_event(map(), ExecutionContext.t()) ::
          {:ok, :dispatch | :none} | {:error, term()}
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

  @spec remote_job_execution(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate remote_job_execution(input, context),
    to: UseCases.GetRemoteJobExecution,
    as: :call

  @spec pipeline_snapshot(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate pipeline_snapshot(input, context), to: UseCases.GetPipelineSnapshot, as: :call

  @spec list_pipelines(map(), ExecutionContext.t()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_pipelines(input, context), to: UseCases.ListPipelines, as: :call

  @spec append_execution_logs(map(), ExecutionContext.t()) :: :ok | {:error, term()}
  defdelegate append_execution_logs(input, context), to: UseCases.AppendExecutionLogs, as: :call

  @spec job_detail(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate job_detail(input, context), to: UseCases.GetJobDetail, as: :call

  @spec list_job_logs(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate list_job_logs(input, context), to: UseCases.ListJobLogs, as: :call

  @spec dispatch_admission(map(), ExecutionContext.t()) ::
          {:ok, :available | {:blocked, term()}} | {:error, term()}
  defdelegate dispatch_admission(input, context), to: UseCases.CheckDispatchAdmission, as: :call

  @spec retry_job(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate retry_job(input, context), to: UseCases.RetryJob, as: :call

  @spec append_log_event(map(), ExecutionContext.t()) :: :ok | {:error, term()}
  defdelegate append_log_event(input, context), to: UseCases.AppendLogEvent, as: :call

  @spec list_active_attempt_ids(map(), ExecutionContext.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  defdelegate list_active_attempt_ids(input, context),
    to: UseCases.ListActiveAttemptIds,
    as: :call

  @spec cancellation_requested(map(), ExecutionContext.t()) ::
          {:ok, boolean()} | {:error, term()}
  defdelegate cancellation_requested(input, context),
    to: UseCases.CancellationRequested,
    as: :call

  @spec heartbeat_attempt(map(), ExecutionContext.t()) ::
          {:ok, Robine.Pipelines.Domain.Attempt.t()} | {:error, term()}
  defdelegate heartbeat_attempt(input, context), to: UseCases.HeartbeatAttempt, as: :call

  @spec heartbeat_runner_attempts(map(), ExecutionContext.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate heartbeat_runner_attempts(input, context),
    to: UseCases.HeartbeatRunnerAttempts,
    as: :call

  @spec reconcile_runner_attempts(map(), ExecutionContext.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate reconcile_runner_attempts(input, context),
    to: UseCases.ReconcileRunnerAttempts,
    as: :call

  @spec reconcile_outbox(map(), ExecutionContext.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate reconcile_outbox(input, context), to: UseCases.ReconcileOutbox, as: :call

  @spec get_idempotent_pipeline(map(), ExecutionContext.t()) ::
          {:ok, Contracts.PipelineView.t()} | {:error, term()}
  defdelegate get_idempotent_pipeline(input, context),
    to: UseCases.GetIdempotentPipeline,
    as: :call

  @spec workflow_revision(map(), ExecutionContext.t()) ::
          {:ok, Robine.Pipelines.Contracts.WorkflowRevisionView.t()} | {:error, term()}
  defdelegate workflow_revision(input, context), to: UseCases.GetWorkflowRevision, as: :call
end
