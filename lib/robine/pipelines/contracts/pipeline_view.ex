defmodule Robine.Pipelines.Contracts.PipelineView do
  @moduledoc "Stable application representation of a pipeline."

  alias Robine.Pipelines.Domain.Pipeline

  @enforce_keys [:id, :repository_id, :workflow_name, :commit_sha, :status, :inserted_at]
  defstruct [:id, :repository_id, :workflow_name, :commit_sha, :status, :inserted_at]

  @type t :: %__MODULE__{
          id: String.t(),
          repository_id: String.t(),
          workflow_name: String.t(),
          commit_sha: String.t(),
          status: Pipeline.status(),
          inserted_at: DateTime.t()
        }

  @spec from_domain(Pipeline.t()) :: t()
  def from_domain(%Pipeline{} = pipeline), do: struct!(__MODULE__, Map.from_struct(pipeline))
end
