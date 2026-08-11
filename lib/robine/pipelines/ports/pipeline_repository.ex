defmodule Robine.Pipelines.Ports.PipelineRepository do
  @moduledoc "Persistence capability required by pipeline use cases."

  alias Robine.Pipelines.Domain.{Pipeline, WorkflowRevision}

  @callback insert(Pipeline.t()) :: :ok | {:error, term()}
  @callback get(String.t()) :: {:ok, Pipeline.t()} | {:error, :not_found | term()}
  @callback update(Pipeline.t()) :: :ok | {:error, term()}
  @callback list_recent(pos_integer()) :: {:ok, [Pipeline.t()]} | {:error, term()}
  @callback list_recent_for_repository(String.t(), pos_integer()) ::
              {:ok, [Pipeline.t()]} | {:error, term()}
  @callback insert_revision(WorkflowRevision.t()) :: :ok | {:error, term()}
  @callback get_revision(String.t()) ::
              {:ok, WorkflowRevision.t()} | {:error, :not_found | term()}

  @optional_callbacks list_recent_for_repository: 2
end
