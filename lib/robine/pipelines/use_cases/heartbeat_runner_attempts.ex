defmodule Robine.Pipelines.UseCases.HeartbeatRunnerAttempts do
  @moduledoc "Renews every active attempt lease owned by one authenticated runner."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies
  alias Robine.Pipelines.Domain.Attempt

  def call(input, %ExecutionContext{
        actor: %{id: runner_id, role: :runner},
        dependencies: %{pipelines: %Dependencies{job_repository: repository} = deps}
      })
      when is_atom(repository) do
    lease_seconds = positive(Map.get(input, :lease_seconds, 60), 60)

    deps.unit_of_work.transaction(fn ->
      with {:ok, attempts} <- repository.list_active_attempts_for_runner_for_update(runner_id),
           :ok <- renew_all(attempts, deps.clock.now(), lease_seconds, repository),
           {:ok, cancellation_ids} <- cancellation_ids(attempts, repository) do
        {:ok,
         %{
           renewed_attempts: length(attempts),
           cancellation_requested_attempt_ids: cancellation_ids
         }}
      end
    end)
  end

  def call(_input, %ExecutionContext{}), do: {:error, :unauthorized}

  defp renew_all(attempts, now, lease_seconds, repository) do
    Enum.reduce_while(attempts, :ok, fn attempt, :ok ->
      with {:ok, renewed} <- Attempt.heartbeat(attempt, now, lease_seconds),
           :ok <- repository.update_attempt(renewed) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp cancellation_ids(attempts, repository) do
    if function_exported?(repository, :cancellation_requested?, 1) do
      Enum.reduce_while(attempts, {:ok, []}, fn attempt, {:ok, ids} ->
        case repository.cancellation_requested?(attempt.idempotency_token) do
          {:ok, true} -> {:cont, {:ok, [attempt.id | ids]}}
          {:ok, false} -> {:cont, {:ok, ids}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, ids} -> {:ok, Enum.reverse(ids)}
        error -> error
      end
    else
      {:ok, []}
    end
  end

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
