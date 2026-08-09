defmodule Robine.Observability.Log do
  @moduledoc "Redaction-safe structured event logging with a bounded metadata allowlist."

  require Logger

  @allowed_keys [
    :correlation_id,
    :delivery_id,
    :pipeline_id,
    :repository_id,
    :job_id,
    :attempt_id,
    :runner_id,
    :github_event,
    :actor_id,
    :trigger,
    :outcome,
    :status,
    :method,
    :rate_limit_remaining,
    :rate_limit_limit
  ]

  @levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]

  @spec event(Logger.level(), String.t(), map() | keyword()) :: :ok
  def event(level, name, metadata \\ %{})
      when level in @levels and is_binary(name) and (is_map(metadata) or is_list(metadata)) do
    safe_metadata =
      metadata
      |> Map.new()
      |> Map.take(@allowed_keys)
      |> Enum.reduce([], fn
        {_key, nil}, result -> result
        {key, value}, result -> [{key, normalize(value)} | result]
      end)

    Logger.log(level, String.slice(name, 0, 96), safe_metadata)
  end

  defp normalize(value) when is_binary(value), do: String.slice(value, 0, 128)
  defp normalize(value) when is_atom(value) or is_integer(value) or is_boolean(value), do: value
  defp normalize(_value), do: "invalid"
end
