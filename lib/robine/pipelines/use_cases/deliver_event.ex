defmodule Robine.Pipelines.UseCases.DeliverEvent do
  @moduledoc "Idempotently projects one durable pipeline event into application state."

  alias Robine.ExecutionContext
  alias Robine.Pipelines
  alias Robine.Repositories
  alias Robine.Pipelines.Dependencies

  @spec call(map(), ExecutionContext.t()) :: {:ok, :dispatch | :none} | {:error, term()}
  def call(
        %{event_id: event_id},
        %ExecutionContext{
          dependencies: %{pipelines: %Dependencies{} = deps}
        } = context
      )
      when is_binary(event_id) do
    with {:ok, event} <- deps.event_outbox.get(event_id),
         {:ok, effect} <- deliver(event, context),
         :ok <- deps.event_outbox.mark_delivered(event_id, deps.clock.now()) do
      {:ok, effect}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, {:invalid_input, :event_id}}

  defp deliver(%{delivered_at: %DateTime{}} = event, _context), do: {:ok, effect(event)}

  defp deliver(
         %{event_type: "pipeline.created", payload: %{"pipeline_id" => pipeline_id}},
         context
       ) do
    with {:ok, _pipeline} <- Pipelines.queue_pipeline(%{pipeline_id: pipeline_id}, context),
         :ok <- sync_checks(pipeline_id, context) do
      {:ok, :dispatch}
    end
  end

  defp deliver(
         %{
           event_type: "pipeline.projection_requested",
           payload: %{"pipeline_id" => pipeline_id} = payload
         },
         context
       ) do
    with :ok <- sync_checks(pipeline_id, context) do
      {:ok, if(payload["dispatch"], do: :dispatch, else: :none)}
    end
  end

  defp deliver(%{event_type: event_type}, _context),
    do: {:error, {:unsupported_event, event_type}}

  defp sync_checks(pipeline_id, context) do
    case Repositories.sync_github_checks(%{pipeline_id: pipeline_id}, context) do
      {:ok, _count} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp effect(%{event_type: "pipeline.created"}), do: :dispatch

  defp effect(%{event_type: "pipeline.projection_requested", payload: payload}),
    do: if(payload["dispatch"], do: :dispatch, else: :none)
end
