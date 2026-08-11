defmodule Robine.Storage.Ports.Repository do
  @moduledoc "Metadata persistence for artifacts and caches."
  alias Robine.Storage.Domain.{Artifact, CacheEntry}
  @callback insert_artifact(Artifact.t(), map()) :: :ok | {:error, term()}
  @callback get_artifact(String.t(), String.t()) ::
              {:ok, Artifact.t()} | {:error, :not_found | term()}
  @callback get_job_artifact(String.t(), String.t()) ::
              {:ok, Artifact.t()} | {:error, :not_found | term()}
  @callback get_job_artifact_by_prefix(String.t(), String.t()) ::
              {:ok, Artifact.t()} | {:error, :not_found | term()}
  @callback get_job_artifacts_by_prefix(String.t(), String.t()) ::
              {:ok, [Artifact.t()]} | {:error, term()}
  @callback get_dependency_artifact(String.t(), String.t(), String.t()) ::
              {:ok, Artifact.t()} | {:error, :not_found | term()}
  @callback upsert_cache(CacheEntry.t(), map()) :: :ok | {:error, term()}
  @callback get_cache(String.t(), String.t()) ::
              {:ok, CacheEntry.t()} | {:error, :not_found | term()}
  @callback touch_cache(String.t(), DateTime.t()) :: :ok | {:error, term()}
  @callback stage_blob_gc(String.t(), DateTime.t(), DateTime.t()) :: :ok | {:error, term()}
end
