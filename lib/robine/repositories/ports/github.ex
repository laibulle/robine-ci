defmodule Robine.Repositories.Ports.GitHub do
  @moduledoc "GitHub content and checks capability owned by the repository context."
  @callback workflow_files(Robine.Repositories.Domain.Repository.t(), String.t()) ::
              {:ok, [%{path: String.t(), content: binary()}]} | {:error, term()}
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

  @optional_callbacks available_repositories: 0
end
