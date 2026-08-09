defmodule Robine.Repositories.Domain.ScheduleOccurrence do
  @moduledoc "Stable identity for one repository workflow cron occurrence."

  @spec idempotency_key(String.t(), String.t(), String.t(), DateTime.t()) :: String.t()
  def idempotency_key(repository_id, path, cron, %DateTime{} = scheduled_for)
      when is_binary(repository_id) and is_binary(path) and is_binary(cron) do
    identity =
      :erlang.term_to_binary({repository_id, path, cron, DateTime.to_iso8601(scheduled_for)})

    digest = :crypto.hash(:sha256, identity) |> Base.url_encode64(padding: false)
    "schedule:" <> digest
  end
end
