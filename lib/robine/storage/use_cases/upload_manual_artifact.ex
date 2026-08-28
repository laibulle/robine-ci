defmodule Robine.Storage.UseCases.UploadManualArtifact do
  @moduledoc "Stores an immutable repository artifact with explicit manual provenance."

  alias Robine.ExecutionContext
  alias Robine.Storage.ArtifactUpload
  alias Robine.Storage.Contracts.ArtifactMetadata
  alias Robine.Storage.Dependencies

  @name ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/
  @content_type ~r/\A[a-zA-Z0-9!#$&^_.+-]+\/[a-zA-Z0-9!#$&^_.+-]+\z/
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @spec call(map(), ExecutionContext.t()) :: {:ok, ArtifactMetadata.t()} | {:error, term()}
  def call(input, %ExecutionContext{
        actor: %{id: actor_id} = actor,
        dependencies: %{storage: %Dependencies{} = deps}
      }) do
    with :ok <- authorize(actor, Map.get(input, :repository_id)),
         {:ok, values} <- validate(input, actor_id),
         true <- deps.repository.repository_exists?(values.repository_id) do
      ArtifactUpload.store(values, deps)
    else
      false -> {:error, :repository_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp authorize(%{role: role}, _repository_id)
       when role in [:administrator, :maintainer],
       do: :ok

  defp authorize(
         %{
           role: :artifact_uploader,
           repository_id: repository_id,
           permissions: permissions
         },
         repository_id
       )
       when is_list(permissions) do
    if "artifacts:write" in permissions, do: :ok, else: {:error, :forbidden}
  end

  defp authorize(_actor, _repository_id), do: {:error, :forbidden}

  defp validate(input, actor_id) do
    values = %{
      repository_id: Map.get(input, :repository_id),
      attempt_id: nil,
      source: :manual,
      uploaded_by_id: actor_id,
      name: Map.get(input, :name),
      content_type: normalize_content_type(Map.get(input, :content_type)),
      content_stream: content_stream(input),
      retention_seconds: Map.get(input, :retention_seconds, 2_592_000)
    }

    cond do
      not valid_uuid?(values.repository_id) ->
        {:error, {:invalid_artifact, :repository_id}}

      not valid_uuid?(values.uploaded_by_id) ->
        {:error, {:invalid_artifact, :uploaded_by_id}}

      not (is_binary(values.name) and Regex.match?(@name, values.name)) ->
        {:error, {:invalid_artifact, :name}}

      not (is_binary(values.content_type) and Regex.match?(@content_type, values.content_type)) ->
        {:error, {:invalid_artifact, :content_type}}

      not valid_stream?(values.content_stream) ->
        {:error, {:invalid_artifact, :content}}

      not (is_integer(values.retention_seconds) and values.retention_seconds > 0) ->
        {:error, {:invalid_artifact, :retention}}

      true ->
        {:ok, values}
    end
  end

  defp normalize_content_type(value) when is_binary(value) do
    value |> String.split(";", parts: 2) |> hd() |> String.trim()
  end

  defp normalize_content_type(_value), do: nil
  defp content_stream(%{content: content}) when is_binary(content), do: [content]
  defp content_stream(%{content_stream: stream}) when not is_nil(stream), do: stream
  defp content_stream(_input), do: :invalid
  defp valid_stream?(:invalid), do: false
  defp valid_stream?(stream), do: not is_nil(Enumerable.impl_for(stream))
  defp valid_uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)
end
