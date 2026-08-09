defmodule Robine.Workflows do
  @moduledoc "Public application API for workflow operations."

  alias Robine.ExecutionContext
  alias Robine.Workflows.Contracts.ValidatedWorkflow
  alias Robine.Workflows.UseCases

  @spec validate(map(), ExecutionContext.t()) ::
          {:ok, ValidatedWorkflow.t()} | {:error, [Robine.Workflows.Domain.Diagnostic.t()]}
  defdelegate validate(input, context), to: UseCases.ValidateWorkflow, as: :call

  @spec prepare_manual_run(map()) :: {:ok, map()} | {:error, term()}
  defdelegate prepare_manual_run(input), to: UseCases.PrepareManualRun, as: :call

  @spec evaluate_schedule(map()) :: {:ok, boolean()} | {:error, term()}
  defdelegate evaluate_schedule(input), to: UseCases.EvaluateSchedule, as: :call

  @spec resolve(map(), ExecutionContext.t()) ::
          {:ok, Contracts.ValidatedWorkflow.t()} | {:error, term()}
  defdelegate resolve(input, context), to: UseCases.ResolveWorkflow, as: :call
end
