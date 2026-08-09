defmodule Robine.Storage.UseCases.UploadArtifact do
  @moduledoc "Stores immutable artifact content and metadata without exposing local paths."
  alias Robine.ExecutionContext
  alias Robine.Storage.Contracts.ArtifactMetadata
  alias Robine.Storage.Dependencies
  alias Robine.Storage.Domain.Artifact

  @name ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/
  @spec call(map(), ExecutionContext.t()) :: {:ok, ArtifactMetadata.t()} | {:error, term()}
  def call(input, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{storage: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer] do
    with {:ok, values} <- validate(input),
         {:ok, blob} <- deps.blob_store.put_stream(values.content_stream) do
      now = DateTime.truncate(deps.clock.now(), :microsecond)

      artifact = %Artifact{
        id: deps.id_generator.generate(),
        repository_id: values.repository_id,
        attempt_id: values.attempt_id,
        name: values.name,
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
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp quotas(deps) do
    %{
      instance_bytes: deps.instance_quota_bytes,
      repository_bytes: deps.repository_quota_bytes
    }
  end

  defp metadata(artifact) do
    struct!(
      ArtifactMetadata,
      Map.take(Map.from_struct(artifact), [
        :id,
        :name,
        :digest,
        :size,
        :created_at,
        :expires_at
      ])
    )
  end

  defp reject_blob(blob_id, now, reason, deps) do
    not_before = DateTime.add(now, deps.gc_grace_seconds, :second)
    _ = deps.repository.stage_blob_gc(blob_id, not_before, now)
    {:error, reason}
  end

  defp validate(input) do
    values = %{
      repository_id: Map.get(input, :repository_id),
      attempt_id: Map.get(input, :attempt_id),
      name: Map.get(input, :name),
      content_stream: content_stream(input),
      retention_seconds: Map.get(input, :retention_seconds, 604_800)
    }

    cond do
      not is_binary(values.repository_id) ->
        {:error, {:invalid_artifact, :repository_id}}

      not is_binary(values.attempt_id) ->
        {:error, {:invalid_artifact, :attempt_id}}

      not (is_binary(values.name) and Regex.match?(@name, values.name)) ->
        {:error, {:invalid_artifact, :name}}

      not valid_stream?(values.content_stream) ->
        {:error, {:invalid_artifact, :content}}

      not (is_integer(values.retention_seconds) and values.retention_seconds > 0) ->
        {:error, {:invalid_artifact, :retention}}

      true ->
        {:ok, values}
    end
  end

  defp content_stream(%{content: content}) when is_binary(content), do: [content]
  defp content_stream(%{content_stream: stream}) when not is_nil(stream), do: stream
  defp content_stream(_input), do: :invalid

  defp valid_stream?(:invalid), do: false
  defp valid_stream?(stream), do: not is_nil(Enumerable.impl_for(stream))
end
