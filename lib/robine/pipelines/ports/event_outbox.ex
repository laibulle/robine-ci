defmodule Robine.Pipelines.Ports.EventOutbox do
  @moduledoc "Durable publication capability for pipeline domain events."

  alias Robine.Pipelines.Domain.{PipelineCreated, PipelineProjectionRequested}

  @callback append(PipelineCreated.t() | PipelineProjectionRequested.t()) ::
              :ok | {:error, term()}
  @callback get(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  @callback mark_delivered(String.t(), DateTime.t()) :: :ok | {:error, term()}
  @callback reconcile_pending(pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
end
