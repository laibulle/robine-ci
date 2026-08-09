defmodule Robine.Pipelines.UseCases.HeartbeatAttempt do
  @moduledoc "Renews an active runner lease without advancing its event sequence."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies
  alias Robine.Pipelines.Domain.Attempt

  @spec call(map(), ExecutionContext.t()) :: {:ok, Attempt.t()} | {:error, term()}
  def call(
        %{idempotency_token: token} = input,
        %ExecutionContext{
          actor: %{role: :administrator},
          dependencies: %{pipelines: %Dependencies{job_repository: repository} = deps}
        }
      )
      when is_binary(token) and is_atom(repository) do
    lease_seconds = positive(Map.get(input, :lease_seconds, 60), 60)

    deps.unit_of_work.transaction(fn ->
      with {:ok, attempt} <- repository.get_attempt_by_token(token),
           {:ok, renewed} <- Attempt.heartbeat(attempt, deps.clock.now(), lease_seconds),
           :ok <- repository.update_attempt(renewed) do
        {:ok, renewed}
      end
    end)
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
