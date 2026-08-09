defmodule Robine.Storage do
  @moduledoc "Public API for immutable artifacts and dependency caches."
  alias Robine.ExecutionContext
  alias Robine.Storage.Contracts.{ArtifactMetadata, CacheMetadata, Download}
  alias Robine.Storage.UseCases

  @spec upload_artifact(map(), ExecutionContext.t()) ::
          {:ok, ArtifactMetadata.t()} | {:error, term()}
  defdelegate upload_artifact(input, context), to: UseCases.UploadArtifact, as: :call
  @spec download_artifact(map(), ExecutionContext.t()) :: {:ok, Download.t()} | {:error, term()}
  defdelegate download_artifact(input, context), to: UseCases.DownloadArtifact, as: :call

  @spec download_job_artifact(map(), ExecutionContext.t()) ::
          {:ok, Download.t()} | {:error, term()}
  defdelegate download_job_artifact(input, context),
    to: UseCases.DownloadJobArtifact,
    as: :call

  @spec download_job_artifact_by_prefix(map(), ExecutionContext.t()) ::
          {:ok, Download.t()} | {:error, term()}
  defdelegate download_job_artifact_by_prefix(input, context),
    to: UseCases.DownloadJobArtifactByPrefix,
    as: :call

  @spec download_dependency_artifact(map(), ExecutionContext.t()) ::
          {:ok, Download.t()} | {:error, term()}
  defdelegate download_dependency_artifact(input, context),
    to: UseCases.DownloadDependencyArtifact,
    as: :call

  @spec save_cache(map(), ExecutionContext.t()) :: {:ok, CacheMetadata.t()} | {:error, term()}
  defdelegate save_cache(input, context), to: UseCases.SaveCache, as: :call
  @spec restore_cache(map(), ExecutionContext.t()) :: {:ok, Download.t()} | {:error, term()}
  defdelegate restore_cache(input, context), to: UseCases.RestoreCache, as: :call
end
