defmodule Robine.Repositories.Ports.SourceControl do
  @moduledoc "Provider-neutral exact-source and status capability owned by repositories."

  @callback workflow_files(Robine.Repositories.Domain.Repository.t(), String.t()) ::
              {:ok, [%{path: String.t(), content: binary()}]} | {:error, term()}
  @callback default_branch_head(Robine.Repositories.Domain.Repository.t()) ::
              {:ok, %{branch: String.t(), sha: String.t()}} | {:error, term()}
  @callback branch_head(Robine.Repositories.Domain.Repository.t(), String.t()) ::
              {:ok, %{branch: String.t(), sha: String.t()}} | {:error, term()}
  @callback source_files(Robine.Repositories.Domain.Repository.t(), String.t()) ::
              {:ok, [{String.t(), binary()}]} | {:error, term()}
  @callback upsert_check(Robine.Repositories.Domain.Repository.t(), map()) ::
              {:ok, integer()} | {:error, term()}
  @callback installation_permissions(Robine.Repositories.Domain.Repository.t()) ::
              {:ok, map()} | {:error, term()}
  @callback available_repositories() ::
              {:ok,
               [
                 %{
                   provider_id: integer(),
                   installation_id: integer(),
                   full_name: String.t(),
                   private: boolean()
                 }
               ]}
              | {:error, term()}

  @callback available_repositories(:github | :gitlab | :forgejo, String.t()) ::
              {:ok, [map()]} | {:error, term()}

  @optional_callbacks available_repositories: 0,
                      available_repositories: 2,
                      default_branch_head: 1,
                      branch_head: 2
end
