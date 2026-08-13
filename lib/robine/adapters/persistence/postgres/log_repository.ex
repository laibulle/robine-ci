defmodule Robine.Adapters.Persistence.Postgres.LogRepository do
  @moduledoc false
  @behaviour Robine.Pipelines.Ports.LogRepository
  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.LogChunk
  alias Robine.Repo

  @impl true
  def insert_all(chunks) do
    now = DateTime.utc_now()
    rows = Enum.map(chunks, &Map.merge(&1, %{inserted_at: now}))

    Repo.insert_all(LogChunk, rows,
      on_conflict: :nothing,
      conflict_target: {:unsafe_fragment, "(tenant_id, attempt_id, sequence)"}
    )

    :ok
  rescue
    error -> {:error, {:log_persistence, error}}
  end

  @impl true
  def list(attempt_id, after_sequence, limit) do
    chunks =
      Repo.all(
        from chunk in LogChunk,
          where: chunk.attempt_id == ^attempt_id and chunk.sequence > ^after_sequence,
          order_by: [asc: chunk.sequence],
          limit: ^limit,
          select: %{
            sequence: chunk.sequence,
            phase: chunk.phase,
            stream: chunk.stream,
            step_position: chunk.step_position,
            step_name: chunk.step_name,
            step_status: chunk.step_status,
            exit_code: chunk.exit_code,
            duration_ms: chunk.duration_ms,
            content: chunk.content
          }
      )

    {:ok, chunks}
  end

  @impl true
  def latest(attempt_id, limit) do
    chunks =
      Repo.all(
        from chunk in LogChunk,
          where: chunk.attempt_id == ^attempt_id,
          order_by: [desc: chunk.sequence],
          limit: ^limit,
          select: %{
            sequence: chunk.sequence,
            phase: chunk.phase,
            stream: chunk.stream,
            step_position: chunk.step_position,
            step_name: chunk.step_name,
            step_status: chunk.step_status,
            exit_code: chunk.exit_code,
            duration_ms: chunk.duration_ms,
            content: chunk.content
          }
      )
      |> Enum.reverse()

    {:ok, chunks}
  end
end
