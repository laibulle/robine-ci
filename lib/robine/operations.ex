defmodule Robine.Operations do
  @moduledoc "Public application API for instance operations."
  alias Robine.ExecutionContext
  alias Robine.Operations.UseCases

  @spec health(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate health(input, context), to: UseCases.GetHealth, as: :call

  @spec prune_retention(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate prune_retention(input, context), to: UseCases.PruneRetention, as: :call
end
