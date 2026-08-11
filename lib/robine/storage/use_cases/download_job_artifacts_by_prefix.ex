defmodule Robine.Storage.UseCases.DownloadJobArtifactsByPrefix do
  @moduledoc "Downloads every newest retained job artifact matching an internal name prefix."
  alias Robine.ExecutionContext
  alias Robine.Storage.Contracts.Download
  alias Robine.Storage.Dependencies

  @spec call(map(), ExecutionContext.t()) :: {:ok, [Download.t()]} | {:error, term()}
  def call(%{job_id: job_id, prefix: prefix}, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{storage: %Dependencies{} = deps}
      })
      when is_binary(job_id) and is_binary(prefix) and byte_size(prefix) in 1..64 do
    with true <- Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/, prefix),
         {:ok, artifacts} <- deps.repository.get_job_artifacts_by_prefix(job_id, prefix) do
      download_all(artifacts, deps)
    else
      false -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp download_all(artifacts, deps) do
    now = deps.clock.now()

    Enum.reduce_while(artifacts, {:ok, []}, fn artifact, {:ok, downloads} ->
      with :ok <- not_expired(artifact.expires_at, now),
           {:ok, content} <- deps.blob_store.get(artifact.blob_id, artifact.digest) do
        download = %Download{
          name: artifact.name,
          digest: artifact.digest,
          size: artifact.size,
          content: content
        }

        {:cont, {:ok, [download | downloads]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, downloads} -> {:ok, Enum.reverse(downloads)}
      error -> error
    end
  end

  defp not_expired(expires_at, now),
    do: if(DateTime.compare(expires_at, now) == :gt, do: :ok, else: {:error, :expired})
end
