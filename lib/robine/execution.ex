defmodule Robine.Execution do
  @moduledoc "Public application API for job execution."

  alias Robine.Execution.Contracts.Result
  alias Robine.ExecutionContext
  alias Robine.Execution.UseCases

  @spec run_job(map(), ExecutionContext.t()) :: {:ok, Result.t()} | {:error, term()}
  defdelegate run_job(input, context), to: UseCases.RunJob, as: :call

  @spec build_local_plan(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate build_local_plan(input, context), to: UseCases.BuildLocalPlan, as: :call

  @spec evaluate_job_condition(map()) :: {:ok, :run | :skip | :wait} | {:error, term()}
  defdelegate evaluate_job_condition(input), to: UseCases.EvaluateJobCondition, as: :call

  @spec build_ci_specification(map(), ExecutionContext.t()) ::
          {:ok, Robine.Execution.Contracts.Specification.t()} | {:error, term()}
  defdelegate build_ci_specification(input, context),
    to: UseCases.BuildCiSpecification,
    as: :call

  @spec reconcile_resources(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate reconcile_resources(input, context), to: UseCases.ReconcileResources, as: :call
end
