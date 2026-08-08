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
  @spec save_cache(map(), ExecutionContext.t()) :: {:ok, CacheMetadata.t()} | {:error, term()}
  defdelegate save_cache(input, context), to: UseCases.SaveCache, as: :call
  @spec restore_cache(map(), ExecutionContext.t()) :: {:ok, Download.t()} | {:error, term()}
  defdelegate restore_cache(input, context), to: UseCases.RestoreCache, as: :call
end
