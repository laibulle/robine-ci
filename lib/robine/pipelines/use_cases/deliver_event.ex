defmodule Robine.Pipelines.UseCases.DeliverEvent do
  @moduledoc "Idempotently projects one durable pipeline event into application state."

  alias Robine.ExecutionContext
  alias Robine.Pipelines
  alias Robine.Pipelines.Dependencies

  @spec call(map(), ExecutionContext.t()) :: {:ok, :delivered} | {:error, term()}
  def call(
        %{event_id: event_id},
        %ExecutionContext{
          dependencies: %{pipelines: %Dependencies{} = deps}
        } = context
      )
      when is_binary(event_id) do
    with {:ok, event} <- deps.event_outbox.get(event_id),
         :ok <- deliver(event, context),
         :ok <- deps.event_outbox.mark_delivered(event_id, deps.clock.now()) do
      {:ok, :delivered}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, {:invalid_input, :event_id}}

  defp deliver(%{delivered_at: %DateTime{}}, _context), do: :ok

  defp deliver(
         %{event_type: "pipeline.created", payload: %{"pipeline_id" => pipeline_id}},
         context
       ) do
    case Pipelines.queue_pipeline(%{pipeline_id: pipeline_id}, context) do
      {:ok, _pipeline} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver(%{event_type: event_type}, _context),
    do: {:error, {:unsupported_event, event_type}}
end
