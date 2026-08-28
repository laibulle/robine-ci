defmodule Robine.Identities.Ports.Repository do
  @moduledoc "Persistence boundary for identity operations."
  @callback bootstrap_user(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback get_local_user(String.t()) :: {:ok, map()} | {:error, :not_found}
  @callback create_session(map()) :: :ok | {:error, term()}
  @callback revoke_session(binary(), DateTime.t()) :: :ok | {:error, term()}
  @callback get_session(binary(), DateTime.t()) :: {:ok, map()} | {:error, :not_found}
  @callback get_user(binary()) :: {:ok, map()} | {:error, :not_found}
  @callback count_usable_administrators() :: non_neg_integer()
  @callback update_role(binary(), atom()) :: :ok | {:error, term()}
  @callback find_or_provision_oidc_user(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback list_users() :: {:ok, [map()]} | {:error, term()}
  @callback create_api_token(map()) :: :ok | {:error, term()}
  @callback list_api_tokens(binary()) :: {:ok, [Robine.Identities.Domain.ApiToken.t()]}
  @callback revoke_api_token(binary(), binary(), DateTime.t()) :: :ok | {:error, term()}
  @callback resolve_api_token(binary(), DateTime.t()) :: {:ok, map()} | {:error, :not_found}
end
