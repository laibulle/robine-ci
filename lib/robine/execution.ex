defmodule Robine.Execution do
  @moduledoc "Public application API for job execution."

  alias Robine.Execution.Contracts.Result
  alias Robine.ExecutionContext
  alias Robine.Execution.UseCases

  @spec run_job(map(), ExecutionContext.t()) :: {:ok, Result.t()} | {:error, term()}
  defdelegate run_job(input, context), to: UseCases.RunJob, as: :call
end
