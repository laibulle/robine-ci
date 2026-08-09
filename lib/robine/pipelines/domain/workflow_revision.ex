defmodule Robine.Pipelines.Domain.WorkflowRevision do
  @moduledoc "Immutable workflow source and normalized graph used by one pipeline."

  @enforce_keys [:id, :pipeline_id, :path, :source, :digest, :normalized_graph, :created_at]
  defstruct [:id, :pipeline_id, :path, :source, :digest, :normalized_graph, :created_at]

  @type t :: %__MODULE__{
          id: String.t(),
          pipeline_id: String.t(),
          path: String.t(),
          source: binary(),
          digest: String.t(),
          normalized_graph: map(),
          created_at: DateTime.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(%{
        id: id,
        pipeline_id: pipeline_id,
        path: path,
        source: source,
        normalized_graph: graph,
        created_at: %DateTime{} = created_at
      })
      when is_binary(id) and is_binary(pipeline_id) and is_binary(path) and path != "" and
             is_binary(source) and byte_size(source) <= 262_144 and is_map(graph) do
    {:ok,
     %__MODULE__{
       id: id,
       pipeline_id: pipeline_id,
       path: path,
       source: source,
       digest: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower),
       normalized_graph: graph,
       created_at: DateTime.truncate(created_at, :microsecond)
     }}
  end

  def new(_input), do: {:error, {:invalid_input, :workflow_revision}}
end
