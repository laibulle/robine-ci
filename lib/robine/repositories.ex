defmodule Robine.Repositories do
  @moduledoc "Public API for repositories and source-control deliveries."
  alias Robine.ExecutionContext
  alias Robine.Repositories.Contracts.RepositoryView
  alias Robine.Repositories.UseCases

  @spec register_source_control_repository(map(), ExecutionContext.t()) ::
          {:ok, RepositoryView.t()} | {:error, term()}
  defdelegate register_source_control_repository(input, context),
    to: UseCases.RegisterSourceControlRepository,
    as: :call

  @spec accept_source_control_webhook(map(), ExecutionContext.t()) ::
          {:ok, :accepted | :duplicate} | {:error, term()}
  defdelegate accept_source_control_webhook(input, context),
    to: UseCases.AcceptSourceControlWebhook,
    as: :call

  @spec discover_source_control_repositories(map(), ExecutionContext.t()) ::
          {:ok, [map()]} | {:error, term()}
  defdelegate discover_source_control_repositories(input, context),
    to: UseCases.DiscoverSourceControlRepositories,
    as: :call

  @spec trust_source_control_repository(map(), ExecutionContext.t()) ::
          {:ok, RepositoryView.t()} | {:error, term()}
  defdelegate trust_source_control_repository(input, context),
    to: UseCases.TrustSourceControlRepository,
    as: :call

  @spec check_source_control_connection(map(), ExecutionContext.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate check_source_control_connection(input, context),
    to: UseCases.CheckSourceControlConnection,
    as: :call

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

  @spec discover_github_repositories(map(), ExecutionContext.t()) ::
          {:ok, [map()]} | {:error, term()}
  defdelegate discover_github_repositories(input, context),
    to: UseCases.DiscoverGitHubRepositories,
    as: :call

  @spec trust_github_repository(map(), ExecutionContext.t()) ::
          {:ok, RepositoryView.t()} | {:error, term()}
  defdelegate trust_github_repository(input, context),
    to: UseCases.TrustGitHubRepository,
    as: :call

  @spec list_manual_workflows(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate list_manual_workflows(input, context),
    to: UseCases.ListManualWorkflows,
    as: :call

  @spec launch_manual_workflow(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate launch_manual_workflow(input, context),
    to: UseCases.LaunchManualWorkflow,
    as: :call

  @spec reconcile_scheduled_workflows(map(), ExecutionContext.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate reconcile_scheduled_workflows(input, context),
    to: UseCases.ReconcileScheduledWorkflows,
    as: :call

  @spec list_scheduled_workflows(map(), ExecutionContext.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate list_scheduled_workflows(input, context),
    to: UseCases.ListScheduledWorkflows,
    as: :call
end
