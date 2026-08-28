defmodule Robine.Storage.UseCases.DownloadJobArtifactByPrefix do
  @moduledoc "Downloads the newest retained artifact matching an internal name prefix."
  alias Robine.ExecutionContext
  alias Robine.Storage.Contracts.Download
  alias Robine.Storage.Dependencies

  @spec call(map(), ExecutionContext.t()) :: {:ok, Download.t()} | {:error, term()}
  def call(%{job_id: job_id, prefix: prefix}, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{storage: %Dependencies{} = deps}
      })
      when is_binary(job_id) and is_binary(prefix) and byte_size(prefix) in 1..64 do
    with true <- Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/, prefix),
         {:ok, artifact} <- deps.repository.get_job_artifact_by_prefix(job_id, prefix),
         :ok <- not_expired(artifact.expires_at, deps.clock.now()),
         {:ok, content} <- deps.blob_store.get(artifact.blob_id, artifact.digest) do
      {:ok,
       %Download{
         name: artifact.name,
         content_type: artifact.content_type,
         digest: artifact.digest,
         size: artifact.size,
         content: content
       }}
    else
      false -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp not_expired(expires_at, now),
    do: if(DateTime.compare(expires_at, now) == :gt, do: :ok, else: {:error, :expired})
end
