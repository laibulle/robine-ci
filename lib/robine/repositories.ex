defmodule Robine.Repositories do
  @moduledoc "Public API for repositories and source-control deliveries."
  alias Robine.ExecutionContext
  alias Robine.Repositories.Contracts.RepositoryView
  alias Robine.Repositories.UseCases

  @spec register_github_repository(map(), ExecutionContext.t()) ::
          {:ok, RepositoryView.t()} | {:error, term()}
  defdelegate register_github_repository(input, context),
    to: UseCases.RegisterGitHubRepository,
    as: :call

  @spec accept_github_webhook(map(), ExecutionContext.t()) ::
          {:ok, :accepted | :duplicate} | {:error, term()}
  defdelegate accept_github_webhook(input, context), to: UseCases.AcceptGitHubWebhook, as: :call
  @spec process_github_delivery(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate process_github_delivery(input, context),
    to: UseCases.ProcessGitHubDelivery,
    as: :call

  @spec sync_github_checks(map(), ExecutionContext.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate sync_github_checks(input, context), to: UseCases.SyncGitHubChecks, as: :call

  @spec fetch_source(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate fetch_source(input, context), to: UseCases.FetchSource, as: :call

  @spec list_repositories(map(), ExecutionContext.t()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_repositories(input, context), to: UseCases.ListRepositories, as: :call

  @spec check_github_installation(map(), ExecutionContext.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate check_github_installation(input, context),
    to: UseCases.CheckGitHubInstallation,
    as: :call
end
