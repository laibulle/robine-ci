defmodule Robine.Transfers do
  @moduledoc "Public application API for bounded runner data transfer preparation."

  alias Robine.ExecutionContext
  alias Robine.Transfers.UseCases

  @spec create_source_archive(map(), ExecutionContext.t()) :: {:ok, binary()} | {:error, term()}
  defdelegate create_source_archive(input, context),
    to: UseCases.CreateSourceArchive,
    as: :call
end
