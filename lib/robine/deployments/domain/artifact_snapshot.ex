defmodule Robine.Deployments.Domain.ArtifactSnapshot do
  @moduledoc "Immutable deployment provenance captured from one successful tag artifact."

  @digest ~r/\A[a-f0-9]{64}\z/
  @tag ~r/\Av\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\z/
  @commit ~r/\A[a-f0-9]{40}\z/
  @filename ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,191}\z/

  @enforce_keys [:artifact_id, :pipeline_id, :filename, :digest, :size, :tag, :commit_sha]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, {:invalid_artifact_snapshot, atom()}}
  def new(attributes) when is_map(attributes) do
    snapshot = struct(__MODULE__, attributes)

    cond do
      not present?(snapshot.artifact_id) -> {:error, {:invalid_artifact_snapshot, :artifact_id}}
      not present?(snapshot.pipeline_id) -> {:error, {:invalid_artifact_snapshot, :pipeline_id}}
      not valid?(snapshot.filename, @filename) -> {:error, {:invalid_artifact_snapshot, :filename}}
      not valid?(snapshot.digest, @digest) -> {:error, {:invalid_artifact_snapshot, :digest}}
      not (is_integer(snapshot.size) and snapshot.size > 0) ->
        {:error, {:invalid_artifact_snapshot, :size}}

      not valid?(snapshot.tag, @tag) -> {:error, {:invalid_artifact_snapshot, :tag}}
      not valid?(snapshot.commit_sha, @commit) ->
        {:error, {:invalid_artifact_snapshot, :commit_sha}}

      true -> {:ok, snapshot}
    end
  end

  def new(_attributes), do: {:error, {:invalid_artifact_snapshot, :shape}}

  defp present?(value), do: is_binary(value) and value != ""
  defp valid?(value, pattern), do: is_binary(value) and Regex.match?(pattern, value)
end
