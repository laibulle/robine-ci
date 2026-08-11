defmodule Robine.Pipelines.UseCases.ListJobLogs do
  @moduledoc "Reads a bounded cursor page or latest retained window of job logs."
  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies

  def call(%{job_id: job_id} = input, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{pipelines: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer, :viewer] and is_binary(job_id) do
    cursor = input |> Map.get(:after, 0) |> max(0)
    limit = input |> Map.get(:limit, 100) |> min(200) |> max(1)

    case deps.job_repository.latest_attempt(job_id) do
      {:ok, attempt} ->
        with {:ok, chunks} <- list_chunks(deps.log_repository, attempt.id, cursor, limit, input) do
          next_cursor =
            case List.last(chunks) do
              nil -> cursor
              chunk -> chunk.sequence
            end

          {:ok,
           %{
             attempt_id: attempt.id,
             chunks: chunks,
             next_cursor: next_cursor,
             has_more: length(chunks) == limit
           }}
        end

      {:error, :not_found} ->
        {:ok, %{attempt_id: nil, chunks: [], next_cursor: cursor, has_more: false}}

      error ->
        error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp list_chunks(repository, attempt_id, _cursor, limit, %{latest: true}),
    do: repository.latest(attempt_id, limit)

  defp list_chunks(repository, attempt_id, cursor, limit, _input),
    do: repository.list(attempt_id, cursor, limit)
end
