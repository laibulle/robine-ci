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
         {:ok, blob} <- deps.blob_store.put(values.content),
         now = DateTime.truncate(deps.clock.now(), :microsecond),
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
         },
         :ok <- deps.repository.insert_artifact(artifact) do
      {:ok,
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
       )}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp validate(input) do
    values = %{
      repository_id: Map.get(input, :repository_id),
      attempt_id: Map.get(input, :attempt_id),
      name: Map.get(input, :name),
      content: Map.get(input, :content),
      retention_seconds: Map.get(input, :retention_seconds, 604_800)
    }

    cond do
      not is_binary(values.repository_id) ->
        {:error, {:invalid_artifact, :repository_id}}

      not is_binary(values.attempt_id) ->
        {:error, {:invalid_artifact, :attempt_id}}

      not (is_binary(values.name) and Regex.match?(@name, values.name)) ->
        {:error, {:invalid_artifact, :name}}

      not is_binary(values.content) ->
        {:error, {:invalid_artifact, :content}}

      not (is_integer(values.retention_seconds) and values.retention_seconds > 0) ->
        {:error, {:invalid_artifact, :retention}}

      true ->
        {:ok, values}
    end
  end
end
