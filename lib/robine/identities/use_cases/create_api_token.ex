defmodule Robine.Identities.UseCases.CreateApiToken do
  @moduledoc "Issues one opaque repository-scoped API token and returns its plaintext once."

  alias Robine.ExecutionContext
  alias Robine.Identities.Dependencies
  alias Robine.Identities.Domain.ApiToken

  @name ~r/\A[\p{L}\p{N}][\p{L}\p{N} ._-]{0,63}\z/u
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @spec call(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  def call(input, %ExecutionContext{
        actor: %{id: user_id, role: role},
        dependencies: %{identities: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer] do
    with {:ok, values} <- validate(input, user_id),
         token <- deps.token_generator.generate("rbn_art"),
         now <- DateTime.truncate(deps.clock.now(), :microsecond),
         credential <- credential(values, token, now, deps),
         :ok <- deps.repository.create_api_token(persistence(credential, token)) do
      emit(:create, :ok)
      {:ok, %{token: token, credential: credential}}
    else
      {:error, reason} = error ->
        emit(:create, outcome(reason))
        error
    end
  end

  def call(_input, %ExecutionContext{}) do
    emit(:create, :forbidden)
    {:error, :forbidden}
  end

  defp validate(input, user_id) do
    name = input |> Map.get(:name) |> normalize_name()
    repository_id = Map.get(input, :repository_id)
    permissions = Map.get(input, :permissions)
    expires_in_days = Map.get(input, :expires_in_days)

    cond do
      not valid_uuid?(user_id) ->
        {:error, {:invalid_api_token, :user_id}}

      not valid_uuid?(repository_id) ->
        {:error, {:invalid_api_token, :repository_id}}

      not (is_binary(name) and Regex.match?(@name, name)) ->
        {:error, {:invalid_api_token, :name}}

      not ApiToken.permissions_valid?(permissions) ->
        {:error, {:invalid_api_token, :permissions}}

      not (is_integer(expires_in_days) and expires_in_days in 1..365) ->
        {:error, {:invalid_api_token, :expiration}}

      true ->
        {:ok,
         %{
           user_id: user_id,
           repository_id: repository_id,
           name: name,
           permissions: permissions,
           expires_in_days: expires_in_days
         }}
    end
  end

  defp credential(values, token, now, deps) do
    %ApiToken{
      id: deps.id_generator.generate(),
      user_id: values.user_id,
      repository_id: values.repository_id,
      name: values.name,
      token_prefix: String.slice(token, 0, 16) <> "…",
      permissions: values.permissions,
      expires_at: DateTime.add(now, values.expires_in_days * 86_400, :second),
      inserted_at: now
    }
  end

  defp persistence(credential, token) do
    credential
    |> Map.from_struct()
    |> Map.put(:token_digest, :crypto.hash(:sha256, token))
  end

  defp normalize_name(name) when is_binary(name), do: String.trim(name)
  defp normalize_name(_name), do: nil
  defp valid_uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)
  defp outcome({:invalid_api_token, _field}), do: :invalid
  defp outcome(reason) when reason in [:repository_not_found, :user_not_found], do: :not_found
  defp outcome(_reason), do: :error

  defp emit(action, outcome) do
    :telemetry.execute(
      [:robine, :identity, :api_token, :lifecycle],
      %{count: 1},
      %{action: action, permission: :artifacts_write, outcome: outcome}
    )
  end
end
