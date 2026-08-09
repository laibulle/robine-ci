defmodule Robine.Storage.UseCases.DownloadJobArtifact do
  @moduledoc "Downloads the newest retained named artifact for an authorized job viewer."
  alias Robine.ExecutionContext
  alias Robine.Storage.Contracts.Download
  alias Robine.Storage.Dependencies

  @spec call(map(), ExecutionContext.t()) :: {:ok, Download.t()} | {:error, term()}
  def call(%{job_id: job_id, name: name}, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{storage: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer, :viewer] and is_binary(job_id) and
             is_binary(name) do
    with {:ok, artifact} <- deps.repository.get_job_artifact(job_id, name),
         :ok <- not_expired(artifact.expires_at, deps.clock.now()),
         {:ok, content} <- deps.blob_store.get(artifact.blob_id, artifact.digest) do
      {:ok,
       %Download{
         name: artifact.name,
         digest: artifact.digest,
         size: artifact.size,
         content: content
       }}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp not_expired(expires_at, now),
    do: if(DateTime.compare(expires_at, now) == :gt, do: :ok, else: {:error, :expired})
end
