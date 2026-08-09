defmodule Robine.Pipelines.Domain.PipelineProjectionRequested do
  @moduledoc "Durable request to project committed pipeline state to external systems."

  @enforce_keys [:event_id, :pipeline_id, :occurred_at, :dispatch]
  defstruct [:event_id, :pipeline_id, :occurred_at, :dispatch]

  @type t :: %__MODULE__{
          event_id: String.t(),
          pipeline_id: String.t(),
          occurred_at: DateTime.t(),
          dispatch: boolean()
        }
end
