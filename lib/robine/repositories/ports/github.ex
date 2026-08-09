defmodule Robine.Repositories.Ports.GitHub do
  @moduledoc "GitHub content and checks capability owned by the repository context."
  @callback workflow_files(Robine.Repositories.Domain.Repository.t(), String.t()) ::
              {:ok, [%{path: String.t(), content: binary()}]} | {:error, term()}
  @callback source_files(Robine.Repositories.Domain.Repository.t(), String.t()) ::
              {:ok, [{String.t(), binary()}]} | {:error, term()}
  @callback upsert_check(Robine.Repositories.Domain.Repository.t(), map()) ::
              {:ok, integer()} | {:error, term()}
end
