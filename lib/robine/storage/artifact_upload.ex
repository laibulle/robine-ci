defmodule Robine.Storage.ArtifactUpload do
  @moduledoc false

  alias Robine.Storage.Contracts.ArtifactMetadata
  alias Robine.Storage.Domain.Artifact

  @spec store(map(), Robine.Storage.Dependencies.t()) ::
          {:ok, ArtifactMetadata.t()} | {:error, term()}
  def store(values, deps) do
    started = System.monotonic_time()

    result =
      with {:ok, blob} <- deps.blob_store.put_stream(values.content_stream) do
        now = DateTime.truncate(deps.clock.now(), :microsecond)

        artifact = %Artifact{
          id: deps.id_generator.generate(),
          repository_id: values.repository_id,
          attempt_id: values.attempt_id,
          source: values.source,
          uploaded_by_id: values.uploaded_by_id,
          name: values.name,
          content_type: values.content_type,
          blob_id: blob.blob_id,
          digest: blob.digest,
          size: blob.size,
          created_at: now,
          expires_at: DateTime.add(now, values.retention_seconds, :second)
        }

        case deps.repository.insert_artifact(artifact, quotas(deps)) do
          :ok -> {:ok, metadata(artifact)}
          {:error, reason} -> reject_blob(blob.blob_id, now, reason, deps)
        end
      end

    :telemetry.execute(
      [:robine, :storage, :artifact, :upload],
      %{
        count: 1,
        duration: System.monotonic_time() - started,
        bytes: uploaded_bytes(result)
      },
      %{source: values.source, outcome: outcome(result)}
    )

    result
  end

  @spec metadata(Artifact.t()) :: ArtifactMetadata.t()
  def metadata(artifact) do
    struct!(
      ArtifactMetadata,
      Map.take(Map.from_struct(artifact), [
        :id,
        :source,
        :uploaded_by_id,
        :name,
        :content_type,
        :digest,
        :size,
        :created_at,
        :expires_at
      ])
    )
  end

  defp quotas(deps) do
    %{
      instance_bytes: deps.instance_quota_bytes,
      repository_bytes: deps.repository_quota_bytes
    }
  end

  defp reject_blob(blob_id, now, reason, deps) do
    not_before = DateTime.add(now, deps.gc_grace_seconds, :second)
    _ = deps.repository.stage_blob_gc(blob_id, not_before, now)
    {:error, reason}
  end

  defp uploaded_bytes({:ok, metadata}), do: metadata.size
  defp uploaded_bytes(_result), do: 0
  defp outcome({:ok, _metadata}), do: :ok
  defp outcome({:error, :object_too_large}), do: :too_large
  defp outcome({:error, {:quota_exceeded, _scope, _limit}}), do: :quota_exceeded
  defp outcome(_result), do: :error
end
