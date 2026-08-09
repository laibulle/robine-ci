defmodule Robine.Pipelines.UseCases.AppendExecutionLogs do
  @moduledoc "Persists bounded, idempotent log chunks from a runner result."
  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies
  alias Robine.Pipelines.Domain.AnsiSanitizer

  @chunk_bytes 64_000

  def call(%{idempotency_token: token, steps: steps}, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{pipelines: %Dependencies{} = deps}
      })
      when is_binary(token) and is_list(steps) do
    with {:ok, attempt} <- deps.job_repository.get_attempt_by_token(token),
         {:ok, chunks} <- chunks(attempt.id, steps) do
      deps.log_repository.insert_all(chunks)
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :invalid_log_batch}

  defp chunks(attempt_id, steps) do
    Enum.with_index(steps, 1)
    |> Enum.reduce_while({:ok, []}, fn {step, position}, {:ok, result} ->
      with {:ok, metadata} <- metadata(step),
           content <- normalize_output(step.output),
           parts <- split(content, @chunk_bytes),
           chunks <-
             Enum.with_index(parts, 1)
             |> Enum.map(fn {part, chunk_index} ->
               Map.merge(metadata, %{
                 attempt_id: attempt_id,
                 sequence: position * 1_000_000 + chunk_index,
                 step_position: position,
                 content: part
               })
             end) do
        {:cont, {:ok, result ++ chunks}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp metadata(%{name: name, status: status, duration_ms: duration_ms} = step)
       when is_binary(name) and is_atom(status) and is_integer(duration_ms) and duration_ms >= 0 do
    {:ok,
     %{
       phase: "execution",
       stream: "combined",
       step_name: name,
       step_status: to_string(status),
       exit_code: Map.get(step, :exit_code),
       duration_ms: duration_ms
     }}
  end

  defp metadata(_step), do: {:error, :invalid_log_step}

  defp normalize_output(output) when is_binary(output) do
    if String.valid?(output),
      do: AnsiSanitizer.strip(output),
      else: "[binary output encoded as base64]\n" <> Base.encode64(output)
  end

  defp normalize_output(_output), do: ""

  defp split("", _limit), do: [""]
  defp split(binary, limit), do: do_split(binary, limit, [])
  defp do_split("", _limit, parts), do: Enum.reverse(parts)

  defp do_split(binary, limit, parts) when byte_size(binary) <= limit,
    do: Enum.reverse([binary | parts])

  defp do_split(binary, limit, parts) do
    size = utf8_boundary(binary, limit)
    <<part::binary-size(^size), rest::binary>> = binary
    do_split(rest, limit, [part | parts])
  end

  defp utf8_boundary(binary, size) do
    candidate = binary_part(binary, 0, size)
    if String.valid?(candidate), do: size, else: utf8_boundary(binary, size - 1)
  end
end
