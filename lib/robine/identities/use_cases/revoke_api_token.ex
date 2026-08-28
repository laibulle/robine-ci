defmodule Robine.Identities.UseCases.RevokeApiToken do
  @moduledoc "Revokes one instance-global API token immediately and idempotently."

  alias Robine.ExecutionContext
  alias Robine.Identities.Dependencies

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @spec call(map(), ExecutionContext.t()) :: :ok | {:error, term()}
  def call(%{token_id: token_id}, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{identities: %Dependencies{} = deps}
      }) do
    result =
      if valid_uuid?(token_id) do
        deps.repository.revoke_api_token(
          token_id,
          DateTime.truncate(deps.clock.now(), :microsecond)
        )
      else
        {:error, {:invalid_api_token, :identifier}}
      end

    emit(outcome(result))
    result
  end

  def call(_input, %ExecutionContext{}) do
    emit(:forbidden)
    {:error, :forbidden}
  end

  defp valid_uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)
  defp outcome(:ok), do: :ok
  defp outcome({:error, :not_found}), do: :not_found
  defp outcome({:error, {:invalid_api_token, _field}}), do: :invalid
  defp outcome(_result), do: :error

  defp emit(outcome) do
    :telemetry.execute(
      [:robine, :identity, :api_token, :lifecycle],
      %{count: 1},
      %{action: :revoke, permission: :artifacts_write, outcome: outcome}
    )
  end
end
