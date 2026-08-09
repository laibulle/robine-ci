defmodule Robine.Pipelines.Contracts.WorkflowRevisionView do
  @moduledoc "Framework-free immutable workflow revision projection."

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
end
