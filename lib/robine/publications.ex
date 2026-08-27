defmodule Robine.Publications do
  @moduledoc "Public API for explicit, immutable public release publication."
  alias Robine.ExecutionContext
  alias Robine.Publications.UseCases

  @spec get_repository_overview(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate get_repository_overview(input, context),
    to: UseCases.GetRepositoryOverview,
    as: :call

  @spec configure_repository(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate configure_repository(input, context),
    to: UseCases.ConfigureRepository,
    as: :call

  @spec resolve_latest(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate resolve_latest(input, context), to: UseCases.ResolveLatest, as: :call
end
