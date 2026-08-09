defmodule Robine.Pipelines.UseCases.AppendLogEvent do
  @moduledoc "Persists one already-redacted runner output event with a stable cursor."
  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies
  alias Robine.Pipelines.Domain.AnsiSanitizer

  def call(
        %{
          attempt_id: attempt_id,
          sequence: sequence,
          step_position: position,
          step_name: name,
          status: status,
          duration_ms: duration,
          content: content
        } = input,
        %ExecutionContext{
          actor: %{role: :administrator},
          dependencies: %{pipelines: %Dependencies{} = deps}
        }
      )
      when is_binary(attempt_id) and is_integer(sequence) and sequence > 0 and
             is_integer(position) and position >= 0 and is_binary(name) and is_atom(status) and
             is_integer(duration) and duration >= 0 and is_binary(content) and
             byte_size(content) <= 64_000 do
    deps.log_repository.insert_all([
      %{
        attempt_id: attempt_id,
        sequence: sequence,
        phase: phase(input),
        step_position: position,
        step_name: name,
        step_status: to_string(status),
        exit_code: Map.get(input, :exit_code),
        duration_ms: duration,
        content: sanitize(content)
      }
    ])
  end

  def call(_input, %ExecutionContext{}), do: {:error, :invalid_log_event}

  defp phase(%{phase: phase}) when phase in [:image_acquisition, :execution, :cleanup],
    do: to_string(phase)

  defp phase(_input), do: "execution"

  defp sanitize(content) do
    if String.valid?(content),
      do: AnsiSanitizer.strip(content),
      else: "[binary log chunk encoded as base64]\n" <> Base.encode64(content)
  end
end
