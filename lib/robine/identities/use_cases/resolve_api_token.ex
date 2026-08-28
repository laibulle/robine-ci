defmodule Robine.Identities.UseCases.ResolveApiToken do
  @moduledoc "Resolves one active opaque API token to its constrained automation actor."

  alias Robine.ExecutionContext
  alias Robine.Identities.Dependencies

  @token ~r/\Arbn_art_[A-Za-z0-9_-]{43}\z/

  @spec call(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, :invalid_api_token}
  def call(%{token: token}, %ExecutionContext{dependencies: %{identities: %Dependencies{} = deps}})
      when is_binary(token) do
    result =
      if Regex.match?(@token, token) do
        deps.repository.resolve_api_token(
          :crypto.hash(:sha256, token),
          DateTime.truncate(deps.clock.now(), :microsecond)
        )
      else
        {:error, :not_found}
      end

    case result do
      {:ok, actor} ->
        emit(:ok)
        {:ok, actor}

      {:error, _reason} ->
        emit(:invalid)
        {:error, :invalid_api_token}
    end
  end

  def call(_input, %ExecutionContext{}) do
    emit(:invalid)
    {:error, :invalid_api_token}
  end

  defp emit(outcome) do
    :telemetry.execute(
      [:robine, :identity, :api_token, :authentication],
      %{count: 1},
      %{permission: :artifacts_write, outcome: outcome}
    )
  end
end
