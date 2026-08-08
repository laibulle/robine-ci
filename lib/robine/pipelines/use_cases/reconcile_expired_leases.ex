defmodule Robine.Pipelines.UseCases.ReconcileExpiredLeases do
  @moduledoc "Fails active attempts whose runner lease expired and releases their graphs."

  alias Robine.ExecutionContext
  alias Robine.Pipelines
  alias Robine.Pipelines.Dependencies

  @spec call(map(), ExecutionContext.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def call(
        input,
        %ExecutionContext{
          actor: %{role: :administrator},
          dependencies: %{pipelines: %Dependencies{job_repository: repository} = deps}
        } = context
      )
      when is_atom(repository) do
    limit = positive(Map.get(input, :limit, 100), 100)

    with {:ok, attempts} <- repository.list_expired_attempts(deps.clock.now(), limit) do
      attempts
      |> Enum.reduce_while({:ok, 0}, fn attempt, {:ok, count} ->
        event = %{
          idempotency_token: attempt.idempotency_token,
          sequence: attempt.last_sequence + 1,
          status: :failed,
          reason: :runner_lost
        }

        case Pipelines.record_runner_event(event, context) do
          {:ok, _attempt} -> {:cont, {:ok, count + 1}}
          {:error, reason} -> {:halt, {:error, {:reconciliation_failed, attempt.id, reason}}}
        end
      end)
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
