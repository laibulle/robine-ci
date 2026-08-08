defmodule Robine.Pipelines.Ports.EventOutbox do
  @moduledoc "Durable publication capability for pipeline domain events."

  alias Robine.Pipelines.Domain.PipelineCreated

  @callback append(PipelineCreated.t()) :: :ok | {:error, term()}
  @callback get(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  @callback mark_delivered(String.t(), DateTime.t()) :: :ok | {:error, term()}
end
