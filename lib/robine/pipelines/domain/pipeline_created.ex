defmodule Robine.Pipelines.Domain.PipelineCreated do
  @moduledoc "Domain event emitted when a pipeline is accepted."

  @enforce_keys [:event_id, :pipeline_id, :repository_id, :occurred_at]
  defstruct [:event_id, :pipeline_id, :repository_id, :occurred_at]

  @type t :: %__MODULE__{
          event_id: String.t(),
          pipeline_id: String.t(),
          repository_id: String.t(),
          occurred_at: DateTime.t()
        }
end
