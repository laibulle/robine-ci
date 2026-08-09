defmodule Robine.Pipelines.Ports.PipelineRepository do
  @moduledoc "Persistence capability required by pipeline use cases."

  alias Robine.Pipelines.Domain.Pipeline

  @callback insert(Pipeline.t()) :: :ok | {:error, term()}
  @callback get(String.t()) :: {:ok, Pipeline.t()} | {:error, :not_found | term()}
  @callback update(Pipeline.t()) :: :ok | {:error, term()}
  @callback list_recent(pos_integer()) :: {:ok, [Pipeline.t()]} | {:error, term()}
end
