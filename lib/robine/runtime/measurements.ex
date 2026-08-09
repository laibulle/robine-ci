defmodule Robine.Runtime.Measurements do
  @moduledoc "Composition-root entry points for periodic infrastructure measurements."

  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{Attempt, Job, Pipeline}
  alias Robine.Repo

  @spec storage_pressure() :: :ok
  def storage_pressure, do: Robine.Adapters.System.DiskAdmission.measure()

  @spec operational_state() :: :ok
  def operational_state do
    queue_snapshot()
    state_counts(Pipeline, [:robine, :pipeline, :state])
    state_counts(Job, [:robine, :job, :state])
    attempt_snapshot()
    :ok
  rescue
    _error -> :ok
  end

  defp queue_snapshot do
    states = ["available", "scheduled", "retryable", "executing"]

    {depth, oldest} =
      Repo.one(
        from job in Oban.Job,
          where: job.state in ^states,
          select: {count(job.id), min(job.inserted_at)}
      )

    age = if oldest, do: max(DateTime.diff(DateTime.utc_now(), oldest, :second), 0), else: 0

    :telemetry.execute([:robine, :queue], %{depth: depth, oldest_age: age}, %{})
  end

  defp state_counts(schema, event) do
    schema
    |> then(fn source ->
      Repo.all(from row in source, group_by: row.status, select: {row.status, count(row.id)})
    end)
    |> Enum.each(fn {status, count} ->
      :telemetry.execute(event, %{count: count}, %{status: status})
    end)
  end

  defp attempt_snapshot do
    active_statuses = [:preparing, :running, :cancelling]
    now = DateTime.utc_now()

    active = Repo.aggregate(from(a in Attempt, where: a.status in ^active_statuses), :count)
    queued = Repo.aggregate(from(a in Attempt, where: a.status == :queued), :count)

    expired =
      Repo.aggregate(
        from(a in Attempt,
          where: a.status in ^[:queued | active_statuses] and a.lease_expires_at < ^now
        ),
        :count
      )

    :telemetry.execute(
      [:robine, :runner, :attempts],
      %{active: active, queued: queued, expired_leases: expired},
      %{}
    )
  end
end
