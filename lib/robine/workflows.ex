defmodule Robine.Workflows do
  @moduledoc "Public application API for workflow operations."

  alias Robine.ExecutionContext
  alias Robine.Workflows.Contracts.ValidatedWorkflow
  alias Robine.Workflows.UseCases

  @spec validate(map(), ExecutionContext.t()) ::
          {:ok, ValidatedWorkflow.t()} | {:error, [Robine.Workflows.Domain.Diagnostic.t()]}
  defdelegate validate(input, context), to: UseCases.ValidateWorkflow, as: :call
end
