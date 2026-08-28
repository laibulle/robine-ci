defmodule Robine.Storage.UseCases.DownloadManualArtifact do
  @moduledoc "Returns a retained manual artifact to an authorized repository user."

  alias Robine.ExecutionContext
  alias Robine.Storage.Contracts.Download
  alias Robine.Storage.Dependencies

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @spec call(map(), ExecutionContext.t()) :: {:ok, Download.t()} | {:error, term()}
  def call(%{repository_id: repository_id, artifact_id: artifact_id}, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{storage: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer, :viewer] do
    with :ok <- valid_identifiers(repository_id, artifact_id),
         {:ok, %{source: :manual} = artifact} <-
           deps.repository.get_artifact(repository_id, artifact_id),
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
      {:ok, _non_manual_artifact} -> {:error, :not_found}
      error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp valid_identifiers(repository_id, artifact_id) do
    if valid_uuid?(repository_id) and valid_uuid?(artifact_id),
      do: :ok,
      else: {:error, :not_found}
  end

  defp valid_uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)

  defp not_expired(expires_at, now),
    do: if(DateTime.compare(expires_at, now) == :gt, do: :ok, else: {:error, :expired})
end
