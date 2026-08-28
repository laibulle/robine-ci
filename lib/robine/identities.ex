defmodule Robine.Identities do
  @moduledoc "Public application API for users, credentials, and sessions."

  alias Robine.ExecutionContext
  alias Robine.Identities.UseCases

  @spec bootstrap_administrator(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate bootstrap_administrator(input, context),
    to: UseCases.BootstrapAdministrator,
    as: :call

  @spec authenticate_local(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate authenticate_local(input, context), to: UseCases.AuthenticateLocal, as: :call

  @spec revoke_session(map(), ExecutionContext.t()) :: :ok | {:error, term()}
  defdelegate revoke_session(input, context), to: UseCases.RevokeSession, as: :call

  @spec resolve_session(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate resolve_session(input, context), to: UseCases.ResolveSession, as: :call

  @spec create_api_token(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate create_api_token(input, context), to: UseCases.CreateApiToken, as: :call

  @spec list_api_tokens(map(), ExecutionContext.t()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_api_tokens(input, context), to: UseCases.ListApiTokens, as: :call

  @spec revoke_api_token(map(), ExecutionContext.t()) :: :ok | {:error, term()}
  defdelegate revoke_api_token(input, context), to: UseCases.RevokeApiToken, as: :call

  @spec resolve_api_token(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate resolve_api_token(input, context), to: UseCases.ResolveApiToken, as: :call

  @spec change_user_role(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate change_user_role(input, context), to: UseCases.ChangeUserRole, as: :call

  @spec start_oidc(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate start_oidc(input, context), to: UseCases.StartOIDC, as: :call

  @spec complete_oidc(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate complete_oidc(input, context), to: UseCases.CompleteOIDC, as: :call

  @spec list_users(map(), ExecutionContext.t()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_users(input, context), to: UseCases.ListUsers, as: :call

  @spec oidc_configuration(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate oidc_configuration(input, context), to: UseCases.GetOIDCConfiguration, as: :call
end
