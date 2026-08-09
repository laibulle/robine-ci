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
          actor: actor,
          dependencies: %{pipelines: %Dependencies{} = deps}
        }
      )
      when is_binary(attempt_id) and is_integer(sequence) and sequence > 0 and
             is_integer(position) and position >= 0 and is_binary(name) and is_atom(status) and
             is_integer(duration) and duration >= 0 and is_binary(content) and
             byte_size(content) <= 64_000 do
    with :ok <- authorize(actor, attempt_id, deps),
         :ok <-
           deps.log_repository.insert_all([
             %{
               attempt_id: attempt_id,
               sequence: sequence,
               phase: phase(input),
               stream: stream(input),
               step_position: position,
               step_name: name,
               step_status: to_string(status),
               exit_code: Map.get(input, :exit_code),
               duration_ms: duration,
               content: sanitize(content)
             }
           ]) do
      emit_condition_evaluation(input)
      :ok
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :invalid_log_event}

  defp authorize(%{role: :administrator}, _attempt_id, _deps), do: :ok

  defp authorize(%{id: runner_id, role: :runner}, attempt_id, deps) do
    with {:ok, attempt} <- deps.job_repository.get_attempt(attempt_id),
         true <- attempt.runner_id == runner_id do
      :ok
    else
      _failure -> {:error, :forbidden}
    end
  end

  defp authorize(_actor, _attempt_id, _deps), do: {:error, :forbidden}

  defp phase(%{phase: phase})
       when phase in [:image_acquisition, :service_preparation, :execution, :cleanup],
       do: to_string(phase)

  defp phase(_input), do: "execution"

  defp stream(%{stream: stream}) when stream in [:stdout, :stderr, :system, :combined],
    do: to_string(stream)

  defp stream(_input), do: "combined"

  defp emit_condition_evaluation(%{
         phase: :execution,
         status: status,
         condition: condition
       })
       when status in [:succeeded, :failed, :cancelled, :timed_out, :skipped] and
              condition in [:success, :failure, :always] do
    :telemetry.execute(
      [:robine, :condition, :evaluation],
      %{count: 1},
      %{
        scope: :step,
        condition: condition,
        outcome: if(status == :skipped, do: :skipped, else: :matched)
      }
    )
  end

  defp emit_condition_evaluation(_input), do: :ok

  defp sanitize(content) do
    if String.valid?(content),
      do: AnsiSanitizer.strip(content),
      else: "[binary log chunk encoded as base64]\n" <> Base.encode64(content)
  end
end
