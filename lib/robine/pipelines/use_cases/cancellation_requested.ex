defmodule Robine.Pipelines.UseCases.CancellationRequested do
  @moduledoc "Returns whether durable cancellation was requested for an attempt."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies

  def call(%{idempotency_token: token}, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{pipelines: %Dependencies{job_repository: repository}}
      })
      when is_binary(token) do
    if function_exported?(repository, :cancellation_requested?, 1),
      do: repository.cancellation_requested?(token),
      else: {:error, :cancellation_projection_unavailable}
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
